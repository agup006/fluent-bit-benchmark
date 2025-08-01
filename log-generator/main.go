package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"sync"
	"time"
)

type LogMessage struct {
	Timestamp   time.Time `json:"timestamp"`
	Level       string    `json:"level"`
	Service     string    `json:"service"`
	Message     string    `json:"message"`
	RequestID   string    `json:"request_id"`
	UserID      string    `json:"user_id"`
	Duration    int       `json:"duration_ms"`
	StatusCode  int       `json:"status_code,omitempty"`
	Method      string    `json:"method,omitempty"`
	Path        string    `json:"path,omitempty"`
}

type Config struct {
	FluentBitURL   string
	MessagesPerSec int
	Duration       time.Duration
	Workers        int
}

func main() {
	var (
		fluentBitURL   = flag.String("url", "http://fluent-bit:9880", "Fluent Bit HTTP input URL")
		messagesPerSec = flag.Int("rate", 1000, "Messages per second to generate")
		duration       = flag.Duration("duration", 60*time.Second, "Test duration")
		workers        = flag.Int("workers", 10, "Number of worker goroutines")
	)
	flag.Parse()

	config := Config{
		FluentBitURL:   *fluentBitURL,
		MessagesPerSec: *messagesPerSec,
		Duration:       *duration,
		Workers:        *workers,
	}

	log.Printf("Starting log generator: %d msg/sec for %v using %d workers", 
		config.MessagesPerSec, config.Duration, config.Workers)

	ctx, cancel := context.WithTimeout(context.Background(), config.Duration)
	defer cancel()

	var wg sync.WaitGroup
	msgChan := make(chan LogMessage, config.MessagesPerSec)

	// Start workers
	for i := 0; i < config.Workers; i++ {
		wg.Add(1)
		go worker(ctx, &wg, msgChan, config.FluentBitURL, i)
	}

	// Generate messages at specified rate
	ticker := time.NewTicker(time.Second / time.Duration(config.MessagesPerSec))
	defer ticker.Stop()

	messageCount := 0
	startTime := time.Now()

	for {
		select {
		case <-ctx.Done():
			close(msgChan)
			wg.Wait()
			elapsed := time.Since(startTime)
			log.Printf("Completed: sent %d messages in %v (%.2f msg/sec)", 
				messageCount, elapsed, float64(messageCount)/elapsed.Seconds())
			return
		case <-ticker.C:
			msg := generateLogMessage(messageCount)
			select {
			case msgChan <- msg:
				messageCount++
			default:
				// Channel full, skip this message
			}
		}
	}
}

func worker(ctx context.Context, wg *sync.WaitGroup, msgChan <-chan LogMessage, url string, workerID int) {
	defer wg.Done()
	
	client := &http.Client{
		Timeout: 5 * time.Second,
	}

	for {
		select {
		case <-ctx.Done():
			return
		case msg, ok := <-msgChan:
			if !ok {
				return
			}
			
			if err := sendMessage(client, url, msg); err != nil {
				log.Printf("Worker %d error: %v", workerID, err)
			}
		}
	}
}

func sendMessage(client *http.Client, url string, msg LogMessage) error {
	jsonData, err := json.Marshal(msg)
	if err != nil {
		return fmt.Errorf("marshal error: %w", err)
	}

	req, err := http.NewRequest("POST", url, bytes.NewBuffer(jsonData))
	if err != nil {
		return fmt.Errorf("request creation error: %w", err)
	}
	
	req.Header.Set("Content-Type", "application/json")
	
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("request error: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusCreated {
		return fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	return nil
}

func generateLogMessage(count int) LogMessage {
	levels := []string{"INFO", "WARN", "ERROR", "DEBUG"}
	services := []string{"api-gateway", "user-service", "order-service", "payment-service", "notification-service"}
	methods := []string{"GET", "POST", "PUT", "DELETE", "PATCH"}
	paths := []string{"/api/users", "/api/orders", "/api/payments", "/api/notifications", "/health"}

	level := levels[count%len(levels)]
	service := services[count%len(services)]
	
	msg := LogMessage{
		Timestamp: time.Now(),
		Level:     level,
		Service:   service,
		RequestID: fmt.Sprintf("req-%d-%d", time.Now().Unix(), count),
		UserID:    fmt.Sprintf("user-%d", count%1000),
		Duration:  50 + (count % 200),
	}

	switch level {
	case "ERROR":
		msg.Message = fmt.Sprintf("Request failed with error: connection timeout after %dms", msg.Duration)
		msg.StatusCode = 500
	case "WARN":
		msg.Message = fmt.Sprintf("Request completed with warning: slow response time %dms", msg.Duration)
		msg.StatusCode = 200
	default:
		msg.Message = fmt.Sprintf("Request processed successfully in %dms", msg.Duration)
		msg.StatusCode = 200
	}

	if count%3 == 0 {
		msg.Method = methods[count%len(methods)]
		msg.Path = paths[count%len(paths)]
	}

	return msg
}