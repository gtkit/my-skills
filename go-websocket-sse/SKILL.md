---
name: go-websocket-sse
description: Go WebSocket and SSE patterns for real-time communication. Covers connection lifecycle, heartbeat, reconnection, broadcast, hub pattern, and production-grade long connection management.
allowed-tools: "Read, Write, Edit, Bash, Glob, Grep"
---

# Go WebSocket & SSE Patterns

## WebSocket Hub Pattern

```go
type Hub struct {
    clients    map[*Client]bool
    broadcast  chan []byte
    register   chan *Client
    unregister chan *Client
    mu         sync.RWMutex
}

type Client struct {
    hub    *Hub
    conn   *websocket.Conn
    send   chan []byte
    userID int64
}

func NewHub() *Hub {
    return &Hub{
        clients:    make(map[*Client]bool),
        broadcast:  make(chan []byte, 256),
        register:   make(chan *Client),
        unregister: make(chan *Client),
    }
}

func (h *Hub) Run(ctx context.Context) {
    for {
        select {
        case <-ctx.Done():
            h.mu.Lock()
            for client := range h.clients {
                close(client.send)
                delete(h.clients, client)
            }
            h.mu.Unlock()
            return
        case client := <-h.register:
            h.mu.Lock()
            h.clients[client] = true
            h.mu.Unlock()
        case client := <-h.unregister:
            h.mu.Lock()
            if _, ok := h.clients[client]; ok {
                delete(h.clients, client)
                close(client.send)
            }
            h.mu.Unlock()
        case message := <-h.broadcast:
            h.mu.RLock()
            for client := range h.clients {
                select {
                case client.send <- message:
                default:
                    // Client buffer full, disconnect
                    close(client.send)
                    delete(h.clients, client)
                }
            }
            h.mu.RUnlock()
        }
    }
}
```

## WebSocket Connection Lifecycle

```go
const (
    writeWait      = 10 * time.Second
    pongWait       = 60 * time.Second
    pingPeriod     = (pongWait * 9) / 10  // must be less than pongWait
    maxMessageSize = 64 * 1024            // 64KB
)

func (c *Client) readPump() {
    defer func() {
        c.hub.unregister <- c
        c.conn.Close()
    }()

    c.conn.SetReadLimit(maxMessageSize)
    c.conn.SetReadDeadline(time.Now().Add(pongWait))
    c.conn.SetPongHandler(func(string) error {
        c.conn.SetReadDeadline(time.Now().Add(pongWait))
        return nil
    })

    for {
        _, message, err := c.conn.ReadMessage()
        if err != nil {
            if websocket.IsUnexpectedCloseError(err,
                websocket.CloseGoingAway,
                websocket.CloseNormalClosure) {
                log.Printf("ws read error: %v", err)
            }
            return
        }
        c.hub.broadcast <- message
    }
}

func (c *Client) writePump() {
    ticker := time.NewTicker(pingPeriod)
    defer func() {
        ticker.Stop()
        c.conn.Close()
    }()

    for {
        select {
        case message, ok := <-c.send:
            c.conn.SetWriteDeadline(time.Now().Add(writeWait))
            if !ok {
                c.conn.WriteMessage(websocket.CloseMessage, []byte{})
                return
            }
            if err := c.conn.WriteMessage(websocket.TextMessage, message); err != nil {
                return
            }
        case <-ticker.C:
            c.conn.SetWriteDeadline(time.Now().Add(writeWait))
            if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
                return
            }
        }
    }
}
```

## WebSocket Upgrader

```go
var upgrader = websocket.Upgrader{
    ReadBufferSize:  4096,
    WriteBufferSize: 4096,
    CheckOrigin: func(r *http.Request) bool {
        origin := r.Header.Get("Origin")
        // Validate allowed origins in production
        return isAllowedOrigin(origin)
    },
    HandshakeTimeout: 10 * time.Second,
}

func ServeWS(hub *Hub, c *gin.Context) {
    conn, err := upgrader.Upgrade(c.Writer, c.Request, nil)
    if err != nil {
        log.Printf("ws upgrade error: %v", err)
        return
    }

    userID := getUserIDFromContext(c)
    client := &Client{
        hub:    hub,
        conn:   conn,
        send:   make(chan []byte, 256),
        userID: userID,
    }
    hub.register <- client

    go client.writePump()
    go client.readPump()
}
```

## SSE (Server-Sent Events)

### SSE Stream Implementation
```go
func (h *Handler) SSEStream(c *gin.Context) {
    c.Header("Content-Type", "text/event-stream")
    c.Header("Cache-Control", "no-cache")
    c.Header("Connection", "keep-alive")
    c.Header("X-Accel-Buffering", "no") // disable Nginx buffering

    ctx := c.Request.Context()
    flusher, ok := c.Writer.(http.Flusher)
    if !ok {
        c.JSON(500, gin.H{"error": "streaming not supported"})
        return
    }

    // Create channel for this client
    eventCh := make(chan Event, 64)
    clientID := h.broker.Subscribe(eventCh)
    defer h.broker.Unsubscribe(clientID)

    // Send initial data
    fmt.Fprintf(c.Writer, "event: connected\ndata: {\"client_id\":\"%s\"}\n\n", clientID)
    flusher.Flush()

    // Heartbeat ticker
    ticker := time.NewTicker(15 * time.Second)
    defer ticker.Stop()

    for {
        select {
        case <-ctx.Done():
            return
        case event := <-eventCh:
            data, _ := json.Marshal(event)
            fmt.Fprintf(c.Writer, "event: %s\ndata: %s\nid: %s\n\n",
                event.Type, data, event.ID)
            flusher.Flush()
        case <-ticker.C:
            fmt.Fprintf(c.Writer, ": heartbeat\n\n")
            flusher.Flush()
        }
    }
}
```

### SSE Broker (Event Distribution)
```go
type Broker struct {
    subscribers map[string]chan Event
    mu          sync.RWMutex
}

func NewBroker() *Broker {
    return &Broker{subscribers: make(map[string]chan Event)}
}

func (b *Broker) Subscribe(ch chan Event) string {
    id := uuid.New().String()
    b.mu.Lock()
    b.subscribers[id] = ch
    b.mu.Unlock()
    return id
}

func (b *Broker) Unsubscribe(id string) {
    b.mu.Lock()
    if ch, ok := b.subscribers[id]; ok {
        close(ch)
        delete(b.subscribers, id)
    }
    b.mu.Unlock()
}

func (b *Broker) Publish(event Event) {
    b.mu.RLock()
    defer b.mu.RUnlock()
    for _, ch := range b.subscribers {
        select {
        case ch <- event:
        default:
            // subscriber too slow, drop event
        }
    }
}
```

## Production Checklist

### WebSocket
- [ ] Ping/pong heartbeat configured (detect dead connections)
- [ ] Read/write deadlines set on every operation
- [ ] Max message size limited (`SetReadLimit`)
- [ ] Origin validation in upgrader (`CheckOrigin`)
- [ ] Client send buffer bounded (drop slow clients)
- [ ] Graceful shutdown closes all connections
- [ ] Authentication before or during upgrade
- [ ] Reconnection logic on client side with exponential backoff

### SSE
- [ ] `X-Accel-Buffering: no` header set (for Nginx)
- [ ] Heartbeat comment sent every 15-30s
- [ ] Event ID included for client reconnection (Last-Event-ID)
- [ ] Channel buffered to avoid blocking publisher
- [ ] Client cleanup on disconnect (context cancellation)
- [ ] Content-Type is `text/event-stream`

### Shared Concerns
- [ ] Connection count monitored (metrics/prometheus)
- [ ] Per-user connection limit enforced
- [ ] Memory usage profiled under load
- [ ] Graceful degradation when too many connections
