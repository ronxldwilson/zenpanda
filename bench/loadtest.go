package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"net/url"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/chromedp/chromedp"
)

func main() {
	cdpURL := flag.String("cdp", "ws://127.0.0.1:9222", "CDP WebSocket URL")
	workers := flag.Int("c", 10, "concurrent workers")
	maxPages := flag.Int("n", 100, "max pages to crawl")
	container := flag.String("container", "zenpanda-test", "Docker container name")
	label := flag.String("label", "ZenPanda", "Test label")
	startURL := flag.String("url", "https://demo-browser.lightpanda.io/amiibo/", "Start URL to crawl")
	flag.Parse()

	fmt.Println("============================================")
	fmt.Printf("  CRAWLER BENCHMARK: %s\n", *label)
	fmt.Println("============================================")
	fmt.Printf("  CDP:         %s\n", *cdpURL)
	fmt.Printf("  Workers:     %d\n", *workers)
	fmt.Printf("  Max pages:   %d\n", *maxPages)
	fmt.Printf("  Start URL:   %s\n", *startURL)
	fmt.Println("--------------------------------------------")

	memBefore := getDockerMem(*container)
	fmt.Printf("  [baseline] MEM: %s\n", memBefore)

	allocCtx, allocCancel := chromedp.NewRemoteAllocator(context.Background(), *cdpURL)
	defer allocCancel()

	baseHost := extractHost(*startURL)

	visited := &sync.Map{}
	queue := make(chan string, 50000)
	var completed atomic.Int64
	var errors atomic.Int64
	var totalBytes atomic.Int64
	var totalLatency atomic.Int64
	latencies := make([]int64, 0, *maxPages)
	var latMu sync.Mutex

	queue <- *startURL

	start := time.Now()

	// Memory sampler
	var peakMem string
	done := make(chan struct{})
	go func() {
		ticker := time.NewTicker(1 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				peakMem = getDockerMem(*container)
			}
		}
	}()

	var wg sync.WaitGroup
	for w := 0; w < *workers; w++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			for {
				if int(completed.Load()+errors.Load()) >= *maxPages {
					return
				}

				var pageURL string
				select {
				case pageURL = <-queue:
				default:
					time.Sleep(200 * time.Millisecond)
					select {
					case pageURL = <-queue:
					default:
						return
					}
				}

				if _, loaded := visited.LoadOrStore(pageURL, true); loaded {
					continue
				}

				reqStart := time.Now()
				links, bodyLen, err := crawlPage(allocCtx, pageURL)
				lat := time.Since(reqStart)

				if err != nil {
					errors.Add(1)
					n := completed.Load() + errors.Load()
					if n%25 == 0 {
						fmt.Printf("  [%d/%d] ERR %s (%s)\n", n, *maxPages, truncURL(pageURL), lat.Round(time.Millisecond))
					}
					continue
				}

				count := completed.Add(1)
				totalBytes.Add(int64(bodyLen))
				totalLatency.Add(int64(lat))
				latMu.Lock()
				latencies = append(latencies, int64(lat))
				latMu.Unlock()

				if count%25 == 0 || count <= 5 {
					fmt.Printf("  [%d/%d] OK  %s (%d bytes, %d links, %s)\n",
						count, *maxPages, truncURL(pageURL), bodyLen, len(links), lat.Round(time.Millisecond))
				}

				for _, link := range links {
					if int(completed.Load()+errors.Load()) >= *maxPages {
						break
					}
					if extractHost(link) == baseHost {
						if _, exists := visited.Load(link); !exists {
							select {
							case queue <- link:
							default:
							}
						}
					}
				}
			}
		}(w)
	}

	wg.Wait()
	close(done)
	elapsed := time.Since(start)

	sortInt64s(latencies)

	fmt.Println("\n--------------------------------------------")
	fmt.Printf("  RESULTS: %s\n", *label)
	fmt.Println("--------------------------------------------")
	c := completed.Load()
	e := errors.Load()
	fmt.Printf("  Completed:    %d\n", c)
	fmt.Printf("  Errors:       %d\n", e)
	fmt.Printf("  Total:        %d / %d\n", c+e, *maxPages)
	fmt.Printf("  Success rate: %.1f%%\n", float64(c)/float64(c+e)*100)
	fmt.Printf("  Total bytes:  %s\n", humanBytes(totalBytes.Load()))
	fmt.Printf("  Duration:     %s\n", elapsed.Round(time.Millisecond))
	if c > 0 {
		fmt.Printf("  Pages/sec:    %.2f\n", float64(c)/elapsed.Seconds())
		avg := time.Duration(totalLatency.Load() / c)
		fmt.Printf("  Avg latency:  %s\n", avg.Round(time.Millisecond))
	}
	if len(latencies) > 0 {
		fmt.Printf("  Min latency:  %s\n", time.Duration(latencies[0]).Round(time.Millisecond))
		fmt.Printf("  P50 latency:  %s\n", time.Duration(pctl(latencies, 50)).Round(time.Millisecond))
		fmt.Printf("  P90 latency:  %s\n", time.Duration(pctl(latencies, 90)).Round(time.Millisecond))
		fmt.Printf("  P99 latency:  %s\n", time.Duration(pctl(latencies, 99)).Round(time.Millisecond))
		fmt.Printf("  Max latency:  %s\n", time.Duration(latencies[len(latencies)-1]).Round(time.Millisecond))
	}
	memAfter := getDockerMem(*container)
	fmt.Printf("  Memory:       %s -> %s (peak: %s)\n", memBefore, memAfter, peakMem)
	fmt.Println("============================================")
}

func crawlPage(allocCtx context.Context, pageURL string) ([]string, int, error) {
	ctx, cancel := chromedp.NewContext(allocCtx)
	defer cancel()

	ctx, tcancel := context.WithTimeout(ctx, 30*time.Second)
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

func extractHost(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil {
		return ""
	}
	return u.Host
}

func truncURL(s string) string {
	if len(s) > 70 {
		return s[:67] + "..."
	}
	return s
}

func getDockerMem(container string) string {
	out, err := exec.Command("docker", "stats", container, "--no-stream",
		"--format", "{{.MemUsage}}").Output()
	if err != nil {
		return "N/A"
	}
	return strings.TrimSpace(string(out))
}

func humanBytes(b int64) string {
	switch {
	case b >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(b)/float64(1<<20))
	case b >= 1<<10:
		return fmt.Sprintf("%.1f KB", float64(b)/float64(1<<10))
	default:
		return fmt.Sprintf("%d B", b)
	}
}

func sortInt64s(d []int64) {
	for i := 1; i < len(d); i++ {
		for j := i; j > 0 && d[j] < d[j-1]; j-- {
			d[j], d[j-1] = d[j-1], d[j]
		}
	}
}

func pctl(sorted []int64, p int) int64 {
	if len(sorted) == 0 {
		return 0
	}
	idx := (p * len(sorted)) / 100
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}
