import Foundation

/// The classic system design interview question archetypes, distilled from
/// the canonical study corpus (system-design-primer's solved designs, the
/// karanpratapsingh case chapters, the awesome-system-design problem tiers,
/// and Alex Xu's volumes). Each archetype carries the signature components
/// interviewers expect to see; detection injects them into the prompt and
/// the UI surfaces them as an expectations checklist.
struct SystemDesignArchetype: Identifiable, Equatable {
    let id: String
    let name: String
    /// Lowercased detection keywords: single words match on word boundaries,
    /// phrases match by containment.
    let keywords: [String]
    /// The 3 to 5 decisions or components interviewers expect for this
    /// problem.
    let signatureComponents: [String]
}

enum SystemDesignArchetypeCatalog {
    static let archetypes: [SystemDesignArchetype] = [
        SystemDesignArchetype(
            id: "urlShortener",
            name: "URL shortener",
            keywords: ["url shortener", "shorten url", "tinyurl", "bitly", "short link", "pastebin"],
            signatureComponents: [
                "base62 encoding or a key generation service for collision free short ids",
                "cache for hot redirects",
                "301 versus 302 redirect choice and its analytics impact",
                "rate limiting on creation"
            ]
        ),
        SystemDesignArchetype(
            id: "newsFeed",
            name: "News feed / timeline",
            keywords: ["news feed", "newsfeed", "timeline", "twitter", "instagram feed", "social feed", "follower feed"],
            signatureComponents: [
                "fan out on write versus fan out on read, hybrid for celebrity accounts",
                "feed cache per user",
                "follow graph storage",
                "ranking or ordering strategy"
            ]
        ),
        SystemDesignArchetype(
            id: "chat",
            name: "Chat / messaging",
            keywords: ["chat", "whatsapp", "messenger", "messaging app", "direct message", "group chat"],
            signatureComponents: [
                "websocket connection servers with connection registry",
                "message queues for one to one and group delivery",
                "presence and last seen tracking",
                "delivery and read receipts with offline push notifications"
            ]
        ),
        SystemDesignArchetype(
            id: "videoStreaming",
            name: "Video streaming",
            keywords: ["video streaming", "youtube", "netflix", "video upload", "video platform", "vod"],
            signatureComponents: [
                "upload plus transcoding pipeline (worker DAG)",
                "adaptive bitrate streaming",
                "CDN edge delivery",
                "metadata versus blob storage separation"
            ]
        ),
        SystemDesignArchetype(
            id: "rideSharing",
            name: "Ride sharing / delivery",
            keywords: ["ride sharing", "uber", "lyft", "doordash", "ride hailing", "driver matching"],
            signatureComponents: [
                "pub/sub location ingestion from drivers",
                "geohash or quadtree proximity index",
                "matching service between supply and demand",
                "ETA computation and surge handling"
            ]
        ),
        SystemDesignArchetype(
            id: "rateLimiter",
            name: "Rate limiter",
            keywords: ["rate limiter", "rate limiting", "throttle", "throttling", "api quota"],
            signatureComponents: [
                "algorithm choice: token bucket, leaky bucket, or sliding window",
                "local versus distributed state (Redis) and its race conditions",
                "429 responses with rate limit headers",
                "per client key strategy"
            ]
        ),
        SystemDesignArchetype(
            id: "webCrawler",
            name: "Web crawler",
            keywords: ["web crawler", "crawler", "spider", "scraper", "crawl"],
            signatureComponents: [
                "URL frontier with politeness per host",
                "dedup via checksums and bloom filters",
                "robots.txt compliance",
                "trap avoidance and distributed workers"
            ]
        ),
        SystemDesignArchetype(
            id: "notifications",
            name: "Notification system",
            keywords: ["notification system", "notifications", "push notification", "apns", "fcm"],
            signatureComponents: [
                "provider abstraction across push, email, and SMS channels",
                "queues per channel with retries and idempotency",
                "user preference and rate limiting layer",
                "delivery tracking"
            ]
        ),
        SystemDesignArchetype(
            id: "autocomplete",
            name: "Search autocomplete",
            keywords: ["autocomplete", "typeahead", "search suggestions", "type ahead"],
            signatureComponents: [
                "trie or precomputed prefix table",
                "top k precomputation pipeline",
                "aggressive caching of hot prefixes",
                "data gathering and ranking refresh"
            ]
        ),
        SystemDesignArchetype(
            id: "keyValueStore",
            name: "Distributed key value store",
            keywords: ["key value store", "key-value store", "dynamo", "distributed store", "kv store"],
            signatureComponents: [
                "consistent hashing ring",
                "replication with quorum reads and writes (N, W, R)",
                "conflict resolution: vector clocks or last write wins",
                "gossip failure detection and anti entropy"
            ]
        ),
        SystemDesignArchetype(
            id: "distributedCache",
            name: "Distributed cache",
            keywords: ["distributed cache", "memcached", "design redis", "cache cluster"],
            signatureComponents: [
                "consistent hashing across nodes",
                "eviction policy (LRU) and TTL strategy",
                "cache update policy: cache aside versus write through",
                "hot key mitigation"
            ]
        ),
        SystemDesignArchetype(
            id: "proximity",
            name: "Proximity / nearby search",
            keywords: ["nearby friends", "proximity", "yelp", "nearby places", "location based", "geo search"],
            signatureComponents: [
                "geospatial index: geohash versus quadtree",
                "periodic location updates via pub/sub",
                "search radius expansion strategy",
                "privacy controls on location sharing"
            ]
        ),
        SystemDesignArchetype(
            id: "collaborativeEditing",
            name: "Collaborative editing",
            keywords: ["google docs", "collaborative editing", "collaborative editor", "shared document", "crdt"],
            signatureComponents: [
                "conflict resolution: operational transforms versus CRDTs",
                "websocket synchronization",
                "document versioning and history",
                "cursor presence broadcasting"
            ]
        ),
        SystemDesignArchetype(
            id: "cloudStorage",
            name: "Cloud file storage",
            keywords: ["dropbox", "google drive", "file sync", "cloud storage", "file storage"],
            signatureComponents: [
                "file chunking with deduplication",
                "delta sync of changed blocks",
                "metadata database separate from block store",
                "change notification to clients"
            ]
        ),
        SystemDesignArchetype(
            id: "payments",
            name: "Payment system",
            keywords: ["payment system", "payments", "digital wallet", "checkout", "stripe", "transaction system"],
            signatureComponents: [
                "idempotency keys preventing double charges",
                "double entry ledger",
                "reconciliation against the payment service provider",
                "exactly once semantics via retries plus dedup"
            ]
        ),
        SystemDesignArchetype(
            id: "messageQueue",
            name: "Distributed message queue",
            keywords: ["message queue", "design kafka", "event stream", "pub sub system", "message broker"],
            signatureComponents: [
                "append only log with partitions",
                "consumer groups and offset management",
                "replication and in sync replicas",
                "delivery guarantee semantics"
            ]
        ),
        SystemDesignArchetype(
            id: "jobScheduler",
            name: "Distributed job scheduler",
            keywords: ["job scheduler", "task scheduler", "cron service", "delayed jobs", "background jobs"],
            signatureComponents: [
                "priority and delay queues",
                "worker pools with heartbeat based failure detection",
                "exactly once execution guarantees",
                "retry policy with backoff"
            ]
        ),
        SystemDesignArchetype(
            id: "booking",
            name: "Booking / reservation",
            keywords: ["ticket booking", "bookmyshow", "seat reservation", "flight booking", "hotel booking", "ticketmaster"],
            signatureComponents: [
                "seat locking: optimistic versus pessimistic",
                "inventory consistency under contention",
                "waiting queue for fairness under load spikes",
                "payment timeout releasing holds"
            ]
        ),
        SystemDesignArchetype(
            id: "metrics",
            name: "Metrics / analytics platform",
            keywords: ["metrics platform", "analytics platform", "time series", "monitoring system", "telemetry pipeline"],
            signatureComponents: [
                "write optimized time series ingestion",
                "pre aggregation and rollups",
                "hot versus cold storage tiering",
                "query fan out and downsampling"
            ]
        ),
        SystemDesignArchetype(
            id: "exchange",
            name: "Stock exchange / matching engine",
            keywords: ["stock exchange", "matching engine", "order book", "trading system"],
            signatureComponents: [
                "in memory matching engine with an order book",
                "sequencer for deterministic ordering",
                "event sourcing for deterministic replay",
                "ultra low latency hot path isolation"
            ]
        )
    ]

    /// Detects the best matching archetype: phrases score higher than single
    /// keywords; single words match on word boundaries only. Returns nil
    /// below a conservative confidence floor so generic transcripts never
    /// pick up a spurious archetype.
    static func detect(in text: String) -> SystemDesignArchetype? {
        let lowered = text.lowercased()
        guard !lowered.isEmpty else { return nil }

        var best: (archetype: SystemDesignArchetype, score: Int)?
        for archetype in archetypes {
            var score = 0
            for keyword in archetype.keywords {
                if keyword.contains(" ") {
                    if lowered.contains(keyword) {
                        score += 3
                    }
                } else if containsWord(keyword, in: lowered) {
                    score += 2
                }
            }
            if score > (best?.score ?? 0) {
                best = (archetype, score)
            }
        }

        guard let best, best.score >= 2 else { return nil }
        return best.archetype
    }

    /// One line of prompt guidance for a detected archetype.
    static func promptGuidance(for archetype: SystemDesignArchetype) -> String {
        "Detected problem archetype: \(archetype.name). Make sure the design explicitly addresses: \(archetype.signatureComponents.joined(separator: "; "))."
    }

    private static func containsWord(_ word: String, in text: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: "\\b\(NSRegularExpression.escapedPattern(for: word))\\b"
        ) else {
            return text.contains(word)
        }
        return regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }
}
