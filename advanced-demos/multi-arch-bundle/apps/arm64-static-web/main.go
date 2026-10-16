package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httptest"
	"os"
)

const responseBody = "hello from the offline ARM64 web server\n"

func handler(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	_, _ = io.WriteString(w, responseBody)
}

func selfTest() error {
	server := httptest.NewServer(http.HandlerFunc(handler))
	defer server.Close()

	response, err := http.Get(server.URL)
	if err != nil {
		return fmt.Errorf("request local test server: %w", err)
	}
	defer response.Body.Close()

	body, err := io.ReadAll(response.Body)
	if err != nil {
		return fmt.Errorf("read local test response: %w", err)
	}
	if response.StatusCode != http.StatusOK || string(body) != responseBody {
		return fmt.Errorf("unexpected response: status=%d body=%q", response.StatusCode, body)
	}

	fmt.Printf("HTTP %d: %s", response.StatusCode, body)
	fmt.Println("ARM64 static web server self-test: PASS")
	return nil
}

func main() {
	selfTestMode := flag.Bool("self-test", false, "serve and verify one HTTP request over loopback")
	flag.Parse()

	if *selfTestMode {
		if err := selfTest(); err != nil {
			log.Print(err)
			os.Exit(1)
		}
		return
	}

	http.HandleFunc("/", handler)
	log.Fatal(http.ListenAndServe(":8080", nil))
}
