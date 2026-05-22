package main

import (
	"context"
	"flag"
	"fmt"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/chromedp/chromedp"
)

func main() {
	cdpURL := flag.String("cdp", "ws://127.0.0.1:9222", "CDP WebSocket URL")
	concurrent := flag.Int("c", 5, "concurrent workers")
	total := flag.Int("n", 30, "total requests")
	container := flag.String("container", "zenpanda-test", "Docker container name")
	label := flag.String("label", "ZenPanda", "Test label")
	flag.Parse()

	urls := []string{
		"https://example.com",
		"https://httpbin.org/html",
		"https://www.iana.org/",
		"https://www.iana.org/domains",
		"https://www.iana.org/about",
	}

	fmt.Println("============================================")
	fmt.Printf("  LOAD TEST: %s\n", *label)
	fmt.Println("============================================")
	fmt.Printf("  CDP:         %s\n", *cdpURL)
	fmt.Printf("  Concurrency: %d\n", *concurrent)
	fmt.Printf("  Total reqs:  %d\n", *total)
	fmt.Println("--------------------------------------------")

	memBefore := getDockerMem(*container)
	fmt.Printf("  [baseline] %s\n", memBefore)

	allocCtx, allocCancel := chromedp.NewRemoteAllocator(context.Background(), *cdpURL)
	defer allocCancel()

	var completed atomic.Int64
	var errors atomic.Int64
	var totalLatency atomic.Int64
	latencies := make([]time.Duration, *total)
	var latMu sync.Mutex

	work := make(chan int, *total)
	for i := 0; i < *total; i++ {
		work <- i
	}
	close(work)

	start := time.Now()

	var wg sync.WaitGroup
	for w := 0; w < *concurrent; w++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for idx := range work {
				url := urls[idx%len(urls)]
				reqStart := time.Now()

				ctx, cancel := chromedp.NewContext(allocCtx)
				var title string
				err := chromedp.Run(ctx,
					chromedp.Navigate(url),
					chromedp.WaitReady("body", chromedp.ByQuery),
					chromedp.Evaluate(`document.title`, &title),
				)
				cancel()

				lat := time.Since(reqStart)
				if err != nil {
					errors.Add(1)
					fmt.Printf("  [%d] ERR %s: %v (%s)\n", idx, url, err, lat.Round(time.Millisecond))
				} else {
					n := completed.Add(1)
					totalLatency.Add(int64(lat))
					latMu.Lock()
					latencies[idx] = lat
					latMu.Unlock()
					if n%5 == 0 || n == int64(*total) {
						fmt.Printf("  [%d/%d] %s — %q (%s)\n", n, *total, url, title, lat.Round(time.Millisecond))
					}
				}
			}
		}()
	}

	wg.Wait()
	elapsed := time.Since(start)

	// Calculate percentiles
	var validLats []time.Duration
	for _, l := range latencies {
		if l > 0 {
			validLats = append(validLats, l)
		}
	}
	sortDurations(validLats)

	fmt.Println("\n--------------------------------------------")
	fmt.Printf("  RESULTS: %s\n", *label)
	fmt.Println("--------------------------------------------")
	fmt.Printf("  Completed:    %d / %d\n", completed.Load(), *total)
	fmt.Printf("  Errors:       %d\n", errors.Load())
	fmt.Printf("  Total time:   %s\n", elapsed.Round(time.Millisecond))
	fmt.Printf("  Reqs/sec:     %.2f\n", float64(completed.Load())/elapsed.Seconds())
	if len(validLats) > 0 {
		avg := time.Duration(totalLatency.Load() / completed.Load())
		fmt.Printf("  Avg latency:  %s\n", avg.Round(time.Millisecond))
		fmt.Printf("  Min latency:  %s\n", validLats[0].Round(time.Millisecond))
		fmt.Printf("  P50 latency:  %s\n", percentile(validLats, 50).Round(time.Millisecond))
		fmt.Printf("  P90 latency:  %s\n", percentile(validLats, 90).Round(time.Millisecond))
		fmt.Printf("  P99 latency:  %s\n", percentile(validLats, 99).Round(time.Millisecond))
		fmt.Printf("  Max latency:  %s\n", validLats[len(validLats)-1].Round(time.Millisecond))
	}
	memAfter := getDockerMem(*container)
	fmt.Printf("  Memory:       %s → %s\n", memBefore, memAfter)
	fmt.Println("============================================")
}

func getDockerMem(container string) string {
	out, err := exec.Command("docker", "stats", container, "--no-stream",
		"--format", "{{.MemUsage}}").Output()
	if err != nil {
		return "N/A"
	}
	return strings.TrimSpace(string(out))
}

func sortDurations(d []time.Duration) {
	for i := 1; i < len(d); i++ {
		for j := i; j > 0 && d[j] < d[j-1]; j-- {
			d[j], d[j-1] = d[j-1], d[j]
		}
	}
}

func percentile(sorted []time.Duration, p int) time.Duration {
	if len(sorted) == 0 {
		return 0
	}
	idx := (p * len(sorted)) / 100
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}
