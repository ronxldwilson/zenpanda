package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"math"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/chromedp/chromedp"
)

func main() {
	cdpURL := flag.String("cdp", "ws://127.0.0.1:9222", "CDP WebSocket URL")
	clients := flag.Int("clients", 10, "number of simultaneous CDP clients")
	pagesEach := flag.Int("pages", 5, "pages each client crawls")
	container := flag.String("container", "zenpanda-test", "Docker container name")
	label := flag.String("label", "ZenPanda", "Test label")
	startURL := flag.String("url", "https://demo-browser.lightpanda.io/amiibo/", "Start URL")
	flag.Parse()

	fmt.Println("============================================")
	fmt.Printf("  MULTI-CLIENT BENCHMARK: %s\n", *label)
	fmt.Println("============================================")
	fmt.Printf("  CDP:              %s\n", *cdpURL)
	fmt.Printf("  Clients:          %d\n", *clients)
	fmt.Printf("  Pages/client:     %d\n", *pagesEach)
	fmt.Printf("  Total pages:      %d\n", *clients**pagesEach)
	fmt.Printf("  Start URL:        %s\n", *startURL)
	fmt.Println("--------------------------------------------")

	memBefore := getContainerMem(*container)
	fmt.Printf("  [baseline] MEM: %s\n", memBefore)

	allocCtx, allocCancel := chromedp.NewRemoteAllocator(context.Background(), *cdpURL)
	defer allocCancel()

	// First, discover some pages to spread across clients
	pages := discoverPages(allocCtx, *startURL, *clients**pagesEach+20)
	if len(pages) < *clients**pagesEach {
		fmt.Printf("  Warning: only found %d pages, some clients will share URLs\n", len(pages))
	}

	type clientResult struct {
		id          int
		pages       int
		errors      int
		totalBytes  int64
		duration    time.Duration
		firstPage   time.Duration
		latencies   []time.Duration
	}

	results := make([]clientResult, *clients)
	var totalErrors atomic.Int64
	var totalSuccess atomic.Int64

	// Memory sampler
	var peakMem string
	done := make(chan struct{})
	go func() {
		ticker := time.NewTicker(500 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				peakMem = getContainerMem(*container)
			}
		}
	}()

	fmt.Println("\n  Starting all clients simultaneously...")
	start := time.Now()

	var wg sync.WaitGroup
	for i := 0; i < *clients; i++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()

			r := clientResult{id: id}
			clientStart := time.Now()

			for p := 0; p < *pagesEach; p++ {
				pageIdx := (id**pagesEach + p) % len(pages)
				pageURL := pages[pageIdx]

				reqStart := time.Now()
				_, bodyLen, err := mcrawlPage(allocCtx, pageURL)
				lat := time.Since(reqStart)

				if err != nil {
					r.errors++
					totalErrors.Add(1)
					fmt.Printf("  [client %d] ERR page %d: %v\n", id, p, err)
					continue
				}

				if p == 0 {
					r.firstPage = lat
				}
				r.pages++
				r.totalBytes += int64(bodyLen)
				r.latencies = append(r.latencies, lat)
				totalSuccess.Add(1)
			}

			r.duration = time.Since(clientStart)
			results[id] = r
		}(i)
	}

	wg.Wait()
	close(done)
	elapsed := time.Since(start)

	memAfter := getContainerMem(*container)

	// Aggregate stats
	var allLatencies []time.Duration
	var firstPages []time.Duration
	var clientDurations []time.Duration
	var totalBytes int64
	successClients := 0

	for _, r := range results {
		if r.pages > 0 {
			successClients++
			firstPages = append(firstPages, r.firstPage)
			clientDurations = append(clientDurations, r.duration)
		}
		totalBytes += r.totalBytes
		allLatencies = append(allLatencies, r.latencies...)
	}

	sortDurations(allLatencies)
	sortDurations(firstPages)
	sortDurations(clientDurations)

	total := totalSuccess.Load() + totalErrors.Load()

	fmt.Println("\n--------------------------------------------")
	fmt.Printf("  RESULTS: %s\n", *label)
	fmt.Println("--------------------------------------------")
	fmt.Printf("  Clients:          %d (%d succeeded)\n", *clients, successClients)
	fmt.Printf("  Total pages:      %d ok, %d err (of %d)\n", totalSuccess.Load(), totalErrors.Load(), total)
	if total > 0 {
		fmt.Printf("  Success rate:     %.1f%%\n", float64(totalSuccess.Load())/float64(total)*100)
	}
	fmt.Printf("  Total bytes:      %s\n", mhumanBytes(totalBytes))
	fmt.Printf("  Wall time:        %s\n", elapsed.Round(time.Millisecond))
	if totalSuccess.Load() > 0 {
		fmt.Printf("  Throughput:       %.2f pages/sec\n", float64(totalSuccess.Load())/elapsed.Seconds())
	}

	if len(firstPages) > 0 {
		fmt.Println()
		fmt.Println("  First-page latency (cold start per client):")
		fmt.Printf("    Min:            %s\n", firstPages[0].Round(time.Millisecond))
		fmt.Printf("    Median:         %s\n", durationPctl(firstPages, 50).Round(time.Millisecond))
		fmt.Printf("    P90:            %s\n", durationPctl(firstPages, 90).Round(time.Millisecond))
		fmt.Printf("    Max:            %s\n", firstPages[len(firstPages)-1].Round(time.Millisecond))
	}

	if len(allLatencies) > 0 {
		fmt.Println()
		fmt.Println("  All-page latency:")
		fmt.Printf("    Min:            %s\n", allLatencies[0].Round(time.Millisecond))
		fmt.Printf("    Median:         %s\n", durationPctl(allLatencies, 50).Round(time.Millisecond))
		fmt.Printf("    P90:            %s\n", durationPctl(allLatencies, 90).Round(time.Millisecond))
		fmt.Printf("    P99:            %s\n", durationPctl(allLatencies, 99).Round(time.Millisecond))
		fmt.Printf("    Max:            %s\n", allLatencies[len(allLatencies)-1].Round(time.Millisecond))
	}

	if len(clientDurations) > 0 {
		fmt.Println()
		fmt.Println("  Client completion time:")
		fmt.Printf("    Fastest:        %s\n", clientDurations[0].Round(time.Millisecond))
		fmt.Printf("    Median:         %s\n", durationPctl(clientDurations, 50).Round(time.Millisecond))
		fmt.Printf("    Slowest:        %s\n", clientDurations[len(clientDurations)-1].Round(time.Millisecond))
	}

	fmt.Println()
	fmt.Printf("  Memory:           %s -> %s (peak: %s)\n", memBefore, memAfter, peakMem)
	fmt.Println("============================================")
}

func discoverPages(allocCtx context.Context, startURL string, need int) []string {
	fmt.Printf("  Discovering %d+ pages from %s ...\n", need, startURL)

	ctx, cancel := chromedp.NewContext(allocCtx)
	defer cancel()
	ctx, tcancel := context.WithTimeout(ctx, 30*time.Second)
	defer tcancel()

	var linksJSON string
	err := chromedp.Run(ctx,
		chromedp.Navigate(startURL),
		chromedp.WaitReady("body", chromedp.ByQuery),
		chromedp.Sleep(2*time.Second),
		chromedp.Evaluate(`JSON.stringify(
			Array.from(document.querySelectorAll('a[href]'))
				.map(a => a.href)
				.filter(h => h.startsWith('http'))
		)`, &linksJSON),
	)
	if err != nil {
		fmt.Printf("  Warning: discovery failed: %v\n", err)
		return []string{startURL}
	}

	var links []string
	json.Unmarshal([]byte(linksJSON), &links)

	seen := map[string]bool{startURL: true}
	unique := []string{startURL}
	for _, l := range links {
		if !seen[l] {
			seen[l] = true
			unique = append(unique, l)
		}
	}

	// If we need more, do a second wave
	if len(unique) < need && len(unique) > 1 {
		for _, pageURL := range unique[1:] {
			if len(unique) >= need {
				break
			}
			ctx2, cancel2 := chromedp.NewContext(allocCtx)
			ctx2, tcancel2 := context.WithTimeout(ctx2, 15*time.Second)

			var moreJSON string
			err := chromedp.Run(ctx2,
				chromedp.Navigate(pageURL),
				chromedp.WaitReady("body", chromedp.ByQuery),
				chromedp.Sleep(1500*time.Millisecond),
				chromedp.Evaluate(`JSON.stringify(
					Array.from(document.querySelectorAll('a[href]'))
						.map(a => a.href)
						.filter(h => h.startsWith('http'))
				)`, &moreJSON),
			)
			tcancel2()
			cancel2()

			if err != nil {
				continue
			}
			var moreLinks []string
			json.Unmarshal([]byte(moreJSON), &moreLinks)
			for _, l := range moreLinks {
				if !seen[l] {
					seen[l] = true
					unique = append(unique, l)
				}
			}
		}
	}

	fmt.Printf("  Discovered %d unique pages\n", len(unique))
	return unique
}

func mcrawlPage(allocCtx context.Context, pageURL string) ([]string, int, error) {
	ctx, cancel := chromedp.NewContext(allocCtx)
	defer cancel()
	ctx, tcancel := context.WithTimeout(ctx, 60*time.Second)
	defer tcancel()

	var htmlLen int
	var linksJSON string

	err := chromedp.Run(ctx,
		chromedp.Navigate(pageURL),
		chromedp.WaitReady("body", chromedp.ByQuery),
		chromedp.Sleep(1500*time.Millisecond),
		chromedp.Evaluate(`document.documentElement.outerHTML.length`, &htmlLen),
		chromedp.Evaluate(`JSON.stringify(
			Array.from(document.querySelectorAll('a[href]'))
				.map(a => a.href)
				.filter(h => h.startsWith('http'))
		)`, &linksJSON),
	)
	if err != nil {
		return nil, 0, err
	}

	var links []string
	json.Unmarshal([]byte(linksJSON), &links)
	return links, htmlLen, nil
}

func getContainerMem(container string) string {
	out, err := exec.Command("docker", "stats", container, "--no-stream",
		"--format", "{{.MemUsage}}").Output()
	if err != nil {
		return "N/A"
	}
	return strings.TrimSpace(string(out))
}

func mhumanBytes(b int64) string {
	switch {
	case b >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(b)/float64(1<<20))
	case b >= 1<<10:
		return fmt.Sprintf("%.1f KB", float64(b)/float64(1<<10))
	default:
		return fmt.Sprintf("%d B", b)
	}
}

func sortDurations(d []time.Duration) {
	for i := 1; i < len(d); i++ {
		for j := i; j > 0 && d[j] < d[j-1]; j-- {
			d[j], d[j-1] = d[j-1], d[j]
		}
	}
}

func durationPctl(sorted []time.Duration, p int) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	idx := int(math.Ceil(float64(p)/100*float64(len(sorted)))) - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}
