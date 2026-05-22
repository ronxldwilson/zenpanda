package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os/exec"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/chromedp/chromedp"
)

func main() {
	pool := flag.Int("pool", 1, "number of concurrent browser tabs")
	url := flag.String("url", "https://example.com", "starting URL to crawl")
	maxPages := flag.Int("max", 50, "max pages to crawl")
	cdpURL := flag.String("cdp", "ws://127.0.0.1:9222", "CDP WebSocket URL")
	containerName := flag.String("container", "zenpanda-test", "Docker container name for stats")
	flag.Parse()

	if flag.NArg() > 0 {
		*url = flag.Arg(0)
	}

	fmt.Println("============================================")
	fmt.Println("  ZenPanda Benchmark")
	fmt.Println("============================================")
	fmt.Printf("  CDP:        %s\n", *cdpURL)
	fmt.Printf("  Start URL:  %s\n", *url)
	fmt.Printf("  Pool size:  %d\n", *pool)
	fmt.Printf("  Max pages:  %d\n", *maxPages)
	fmt.Println("--------------------------------------------")

	dockerMem("baseline", *containerName)

	allocCtx, allocCancel := chromedp.NewRemoteAllocator(context.Background(), *cdpURL)
	defer allocCancel()

	visited := &sync.Map{}
	queue := make(chan string, 10000)
	var crawled atomic.Int64
	var errors atomic.Int64
	var totalBytes atomic.Int64

	queue <- *url

	start := time.Now()
	var memSamples []string
	done := make(chan struct{})

	go func() {
		ticker := time.NewTicker(500 * time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ticker.C:
				memSamples = append(memSamples, dockerMem("", *containerName))
			}
		}
	}()

	var wg sync.WaitGroup
	for i := 0; i < *pool; i++ {
		wg.Add(1)
		go func(workerID int) {
			defer wg.Done()
			for {
				if int(crawled.Load()) >= *maxPages {
					return
				}
				var pageURL string
				select {
				case pageURL = <-queue:
				default:
					time.Sleep(100 * time.Millisecond)
					select {
					case pageURL = <-queue:
					default:
						return
					}
				}

				if _, loaded := visited.LoadOrStore(pageURL, true); loaded {
					continue
				}

				count := crawled.Add(1)
				if int(count) > *maxPages {
					return
				}

				links, bodyLen, err := crawlPage(allocCtx, pageURL)
				if err != nil {
					errors.Add(1)
					fmt.Printf("  [%d] ERR  %s: %v\n", workerID, pageURL, err)
					continue
				}
				totalBytes.Add(int64(bodyLen))
				fmt.Printf("  [%d] OK   %s (%d bytes, %d links)\n", workerID, pageURL, bodyLen, len(links))

				for _, link := range links {
					if int(crawled.Load()) >= *maxPages {
						break
					}
					if _, exists := visited.Load(link); !exists {
						select {
						case queue <- link:
						default:
						}
					}
				}
			}
		}(i)
	}

	wg.Wait()
	close(done)
	elapsed := time.Since(start)

	fmt.Println("\n--------------------------------------------")
	fmt.Println("  RESULTS")
	fmt.Println("--------------------------------------------")
	fmt.Printf("  Pages crawled:  %d\n", crawled.Load())
	fmt.Printf("  Errors:         %d\n", errors.Load())
	fmt.Printf("  Total bytes:    %s\n", humanBytes(totalBytes.Load()))
	fmt.Printf("  Duration:       %s\n", elapsed.Round(time.Millisecond))
	fmt.Printf("  Pages/sec:      %.1f\n", float64(crawled.Load())/elapsed.Seconds())

	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	fmt.Printf("  Go heap:        %s\n", humanBytes(int64(m.Alloc)))

	dockerMem("final", *containerName)

	fmt.Println("============================================")
}

func crawlPage(allocCtx context.Context, pageURL string) ([]string, int, error) {
	ctx, cancel := chromedp.NewContext(allocCtx)
	defer cancel()

	ctx, cancel = context.WithTimeout(ctx, 15*time.Second)
	defer cancel()

	var htmlLen int
	var linksJSON string

	err := chromedp.Run(ctx,
		chromedp.Navigate(pageURL),
		chromedp.WaitReady("body", chromedp.ByQuery),
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

func dockerMem(label string, container string) string {
	out, err := exec.Command("docker", "stats", container, "--no-stream",
		"--format", "MEM: {{.MemUsage}} | CPU: {{.CPUPerc}}").Output()
	if err != nil {
		return ""
	}
	s := strings.TrimSpace(string(out))
	if label != "" {
		fmt.Printf("  [%s] %s\n", label, s)
	}
	return s
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
