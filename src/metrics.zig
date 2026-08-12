// Hand-rolled Prometheus metrics: HTTP request counter + latency histogram
// (fixed buckets), process uptime gauge, and the curation-run counters
// recorded by `curation_job.run` at the end of each executed run.
// Plus the EPUB-generation and pi-evaluation families recorded by the
// download resolver and the longevity evaluator.
// ponytail: fixed histogram buckets; tune buckets when real latency
// distribution is known. ponytail: concrete Metrics handle passed to
// seams; upgrade to a Recorder interface if a second backend ever lands.
const std = @import("std");

const Kind = @import("store.zig").Kind;

/// Histogram bucket upper bounds in seconds (Prometheus _bucket{le=...}).
/// `inf` is added implicitly at render time.
pub const buckets_seconds: []const f64 = &.{ 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10 };

pub const content_type: []const u8 = "text/plain; version=0.0.4";

const Observation = struct {
    method: []const u8,
    path: []const u8,
    latency_ns: u64,
};

pub const Metrics = struct {
    start_time_ns: i128,
    observations: std.ArrayList(Observation),
    /// Cumulative curation-run counters, reset on restart (design D4).
    runs_total: u64 = 0,
    items_fetched_total: u64 = 0,
    items_curated_news: u64 = 0,
    items_curated_knowledge: u64 = 0,
    source_fetch_errors_total: u64 = 0,
    items_pruned_total: u64 = 0,
    /// Per-kind EPUB generation counters, recorded by `download.resolve`
    /// on each non-empty resolve.
    epub_generations_news: u64 = 0,
    epub_generations_knowledge: u64 = 0,
    /// pi-evaluation counters, recorded by `longevity.classify` on the
    /// cache-miss invoke path.
    pi_evaluations_total: u64 = 0,
    pi_evaluations_failed_total: u64 = 0,
    /// One latency sample per actual pi invocation (nanoseconds).
    pi_eval_latencies: std.ArrayList(u64),

    pub fn init(start_time_ns: i128) Metrics {
        return .{
            .start_time_ns = start_time_ns,
            .observations = .empty,
            .pi_eval_latencies = .empty,
        };
    }

    pub fn deinit(self: *Metrics, gpa: std.mem.Allocator) void {
        self.observations.deinit(gpa);
        self.pi_eval_latencies.deinit(gpa);
    }

    /// Record one HTTP request observation.
    pub fn observe(self: *Metrics, gpa: std.mem.Allocator, method: []const u8, path: []const u8, latency_ns: u64) std.mem.Allocator.Error!void {
        try self.observations.append(gpa, .{
            .method = method,
            .path = path,
            .latency_ns = latency_ns,
        });
    }

    /// Record one executed curation run. Called from `curation_job.run` at the
    /// end of a run that actually executed (never on a `.busy` probe).
    pub fn recordCurationRun(self: *Metrics, fetched: u64, news: u64, knowledge: u64, source_errors: u64, pruned: u64) void {
        self.runs_total += 1;
        self.items_fetched_total += fetched;
        self.items_curated_news += news;
        self.items_curated_knowledge += knowledge;
        self.source_fetch_errors_total += source_errors;
        self.items_pruned_total += pruned;
    }

    /// Record one EPUB generation labeled by `kind`. Called once per EPUB
    /// actually built by `download.resolve` (a nothing-new resolve records
    /// nothing).
    pub fn recordEpubGeneration(self: *Metrics, kind: Kind) void {
        switch (kind) {
            .news => self.epub_generations_news += 1,
            .knowledge => self.epub_generations_knowledge += 1,
        }
    }

    /// Record one actual pi invocation: increment the evaluations counter,
    /// append the latency sample, and bump the failed counter when `failed`
    /// is true. Called once per cache-miss invoke inside `longevity.classify`.
    pub fn recordPiEval(self: *Metrics, gpa: std.mem.Allocator, elapsed_ns: u64, failed: bool) std.mem.Allocator.Error!void {
        self.pi_evaluations_total += 1;
        try self.pi_eval_latencies.append(gpa, elapsed_ns);
        if (failed) self.pi_evaluations_failed_total += 1;
    }

    /// Render Prometheus exposition text. `now_ns` should be from the same
    /// clock as `start_time_ns`. Caller owns the returned slice.
    pub fn render(self: *const Metrics, gpa: std.mem.Allocator, now_ns: i128) (std.mem.Allocator.Error || std.Io.Writer.Error)![]u8 {
        var aw: std.Io.Writer.Allocating = .init(gpa);
        defer aw.deinit();
        const w = &aw.writer;

        const Series = struct {
            method: []const u8,
            path: []const u8,
            count: u64 = 0,
            sum_ns: u128 = 0,
            bucket_counts: [buckets_seconds.len + 1]u64 = .{0} ** (buckets_seconds.len + 1),
        };
        var series: std.ArrayList(Series) = .empty;
        defer series.deinit(gpa);

        // Aggregate by (method, path).
        for (self.observations.items) |obs| {
            var found: ?usize = null;
            for (series.items, 0..) |s, i| {
                if (std.mem.eql(u8, s.method, obs.method) and std.mem.eql(u8, s.path, obs.path)) {
                    found = i;
                    break;
                }
            }
            const idx = findBucket(obs.latency_ns);
            if (found) |i| {
                var s = &series.items[i];
                s.count += 1;
                s.sum_ns += obs.latency_ns;
                s.bucket_counts[idx] += 1;
            } else {
                series.append(gpa, .{
                    .method = obs.method,
                    .path = obs.path,
                    .count = 1,
                    .sum_ns = obs.latency_ns,
                    .bucket_counts = blk: {
                        var bc: [buckets_seconds.len + 1]u64 = .{0} ** (buckets_seconds.len + 1);
                        bc[idx] = 1;
                        break :blk bc;
                    },
                }) catch return error.OutOfMemory;
            }
        }

        // Emit counter and histogram families per series.
        for (series.items) |s| {
            try w.print(
                "# HELP curation_http_requests_total Total HTTP requests.\n# TYPE curation_http_requests_total counter\ncuration_http_requests_total{{method=\"{s}\",path=\"{s}\"}} {d}\n",
                .{ s.method, s.path, s.count },
            );
            try w.print(
                "# HELP curation_http_request_duration_seconds HTTP request latency in seconds.\n# TYPE curation_http_request_duration_seconds histogram\n",
                .{},
            );
            var cumulative: u64 = 0;
            for (buckets_seconds, 0..) |b, i| {
                cumulative += s.bucket_counts[i];
                try w.print(
                    "curation_http_request_duration_seconds_bucket{{method=\"{s}\",path=\"{s}\",le=\"{d}\"}} {d}\n",
                    .{ s.method, s.path, b, cumulative },
                );
            }
            cumulative += s.bucket_counts[buckets_seconds.len];
            try w.print(
                "curation_http_request_duration_seconds_bucket{{method=\"{s}\",path=\"{s}\",le=\"+Inf\"}} {d}\n",
                .{ s.method, s.path, cumulative },
            );
            const sum_seconds: f64 = @as(f64, @floatFromInt(s.sum_ns)) / 1_000_000_000.0;
            try w.print(
                "curation_http_request_duration_seconds_sum{{method=\"{s}\",path=\"{s}\"}} {d}\n",
                .{ s.method, s.path, sum_seconds },
            );
            try w.print(
                "curation_http_request_duration_seconds_count{{method=\"{s}\",path=\"{s}\"}} {d}\n",
                .{ s.method, s.path, s.count },
            );
        }

        // Uptime gauge.
        const uptime_seconds: f64 = @as(f64, @floatFromInt(now_ns - self.start_time_ns)) / 1_000_000_000.0;
        try w.print(
            "# HELP curation_uptime_seconds Process uptime in seconds.\n# TYPE curation_uptime_seconds gauge\ncuration_uptime_seconds {d}\n",
            .{uptime_seconds},
        );

        // Curation-run counters (design D4/D5). Zero-valued families are still
        // emitted so a scraper observes the family exists.
        try w.print(
            \\# HELP curation_runs_total Total curation runs executed.
            \\# TYPE curation_runs_total counter
            \\curation_runs_total {d}
            \\
            \\# HELP curation_items_fetched_total Total items received across all sources per run.
            \\# TYPE curation_items_fetched_total counter
            \\curation_items_fetched_total {d}
            \\
            \\# HELP curation_items_curated_total Total items stored, labeled by kind.
            \\# TYPE curation_items_curated_total counter
            \\curation_items_curated_total{{kind="news"}} {d}
            \\curation_items_curated_total{{kind="knowledge"}} {d}
            \\
            \\# HELP curation_source_fetch_errors_total Total source-acquisition failures.
            \\# TYPE curation_source_fetch_errors_total counter
            \\curation_source_fetch_errors_total {d}
            \\
            \\# HELP curation_items_pruned_total Total records removed by retention prune.
            \\# TYPE curation_items_pruned_total counter
            \\curation_items_pruned_total {d}
            \\
        , .{
            self.runs_total,
            self.items_fetched_total,
            self.items_curated_news,
            self.items_curated_knowledge,
            self.source_fetch_errors_total,
            self.items_pruned_total,
        });

        // EPUB-generation counter (recordEpubGeneration). Zero-valued
        // families are still emitted so a scraper observes them exists.
        try w.print(
            \\# HELP curation_epub_generations_total Total EPUBs built by the download resolver, labeled by kind.
            \\# TYPE curation_epub_generations_total counter
            \\curation_epub_generations_total{{kind="news"}} {d}
            \\curation_epub_generations_total{{kind="knowledge"}} {d}
            \\
        , .{
            self.epub_generations_news,
            self.epub_generations_knowledge,
        });

        // pi-evaluation counters (recordPiEval).
        try w.print(
            \\# HELP curation_pi_evaluations_total Total actual pi invocations by the longevity evaluator.
            \\# TYPE curation_pi_evaluations_total counter
            \\curation_pi_evaluations_total {d}
            \\
            \\# HELP curation_pi_evaluations_failed_total Total pi invocations that errored or yielded an unparseable label.
            \\# TYPE curation_pi_evaluations_failed_total counter
            \\curation_pi_evaluations_failed_total {d}
            \\
        , .{
            self.pi_evaluations_total,
            self.pi_evaluations_failed_total,
        });

        // pi-evaluation latency histogram (no labels — design D4/D8).
        // Aggregate the per-invocation samples into the fixed buckets.
        try w.print(
            "# HELP curation_pi_evaluation_duration_seconds Latency of actual pi invocations in seconds.\n# TYPE curation_pi_evaluation_duration_seconds histogram\n",
            .{},
        );
        var pi_buckets: [buckets_seconds.len + 1]u64 = .{0} ** (buckets_seconds.len + 1);
        var pi_sum_ns: u128 = 0;
        for (self.pi_eval_latencies.items) |ns| {
            pi_buckets[findBucket(ns)] += 1;
            pi_sum_ns += ns;
        }
        var pi_cumulative: u64 = 0;
        for (buckets_seconds, 0..) |b, i| {
            pi_cumulative += pi_buckets[i];
            try w.print(
                "curation_pi_evaluation_duration_seconds_bucket{{le=\"{d}\"}} {d}\n",
                .{ b, pi_cumulative },
            );
        }
        pi_cumulative += pi_buckets[buckets_seconds.len];
        try w.print(
            "curation_pi_evaluation_duration_seconds_bucket{{le=\"+Inf\"}} {d}\n",
            .{pi_cumulative},
        );
        const pi_sum_seconds: f64 = @as(f64, @floatFromInt(pi_sum_ns)) / 1_000_000_000.0;
        try w.print(
            "curation_pi_evaluation_duration_seconds_sum {d}\ncuration_pi_evaluation_duration_seconds_count {d}\n",
            .{ pi_sum_seconds, pi_cumulative },
        );

        // Copy out of the internal buffer so the caller owns a stable slice.
        const written = aw.written();
        return gpa.dupe(u8, written);
    }

    /// Returns 0-based bucket index for `latency_ns`: the smallest bucket whose
    /// upper bound is >= latency. Falls into `+Inf` (last bucket) otherwise.
    fn findBucket(latency_ns: u64) u8 {
        const secs: f64 = @as(f64, @floatFromInt(latency_ns)) / 1_000_000_000.0;
        for (buckets_seconds, 0..) |b, i| {
            if (secs <= b) return @intCast(i);
        }
        return @intCast(buckets_seconds.len); // +Inf bucket
    }
};

test "metrics: content type matches Prometheus text 0.0.4" {
    try std.testing.expectEqualStrings("text/plain; version=0.0.4", content_type);
}

test "metrics: empty metrics still exposes uptime gauge" {
    var m = Metrics.init(0);
    defer m.deinit(std.testing.allocator);
    const text = try m.render(std.testing.allocator, 1_500_000_000);
    defer std.testing.allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_uptime_seconds ") != null);
}

test "metrics: observations produce counter and histogram lines" {
    var m = Metrics.init(0);
    defer m.deinit(std.testing.allocator);

    try m.observe(std.testing.allocator, "GET", "/healthz", 250_000_000); // 0.25s
    try m.observe(std.testing.allocator, "GET", "/healthz", 10_000_000); // 0.01s
    try m.observe(std.testing.allocator, "GET", "/metrics", 5_000_000); // 0.005s

    const text = try m.render(std.testing.allocator, 1_000_000_000);
    defer std.testing.allocator.free(text);

    // Counter family present and shows 2 for /healthz.
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_http_requests_total") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "method=\"GET\",path=\"/healthz\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "method=\"GET\",path=\"/metrics\"} 1") != null);

    // Histogram family and buckets present.
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_http_request_duration_seconds_bucket") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "le=\"+Inf\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_sum{") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "_count{") != null);
}

test "metrics: request latency placed in correct bucket" {
    var m = Metrics.init(0);
    defer m.deinit(std.testing.allocator);

    try m.observe(std.testing.allocator, "GET", "/healthz", 3_000_000); // 0.003s → first bucket (0.005)
    const text = try m.render(std.testing.allocator, 0);
    defer std.testing.allocator.free(text);

    // le=0.005 should be 1 for the cumulative count.
    try std.testing.expect(std.mem.indexOf(u8, text, "le=\"0.005\"} 1") != null);
}

test "metrics: empty registry renders all five curation families at zero" {
    var m = Metrics.init(0);
    defer m.deinit(std.testing.allocator);

    const text = try m.render(std.testing.allocator, 0);
    defer std.testing.allocator.free(text);

    // Each family: HELP + TYPE + sample at 0.
    try std.testing.expect(std.mem.indexOf(u8, text, "# TYPE curation_runs_total counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_runs_total 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "# TYPE curation_items_fetched_total counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_items_fetched_total 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_items_curated_total{kind=\"news\"} 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_items_curated_total{kind=\"knowledge\"} 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "# TYPE curation_source_fetch_errors_total counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_source_fetch_errors_total 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "# TYPE curation_items_pruned_total counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_items_pruned_total 0") != null);
}

test "metrics: recordCurationRun increments the six counters and they render correctly" {
    var m = Metrics.init(0);
    defer m.deinit(std.testing.allocator);

    m.recordCurationRun(3, 2, 1, 1, 0);
    m.recordCurationRun(5, 0, 4, 0, 7);

    const text = try m.render(std.testing.allocator, 0);
    defer std.testing.allocator.free(text);

    // runs_total = 2
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_runs_total 2") != null);
    // items_fetched_total = 3 + 5 = 8
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_items_fetched_total 8") != null);
    // items_curated{kind=news} = 2 + 0 = 2
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_items_curated_total{kind=\"news\"} 2") != null);
    // items_curated{kind=knowledge} = 1 + 4 = 5
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_items_curated_total{kind=\"knowledge\"} 5") != null);
    // source_fetch_errors_total = 1 + 0 = 1
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_source_fetch_errors_total 1") != null);
    // items_pruned_total = 0 + 7 = 7
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_items_pruned_total 7") != null);

    // Existing request counter / uptime still present (no regression).
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_uptime_seconds") != null);
}

test "metrics: items_curated_total carries only the kind label" {
    var m = Metrics.init(0);
    defer m.deinit(std.testing.allocator);

    m.recordCurationRun(1, 1, 0, 0, 0);
    const text = try m.render(std.testing.allocator, 0);
    defer std.testing.allocator.free(text);

    // The line must not carry a method= or path= label.
    if (std.mem.indexOf(u8, text, "curation_items_curated_total{")) |idx| {
        const line_start = std.mem.lastIndexOf(u8, text[0..idx], "\n");
        const slice_start = if (line_start) |ls| ls + 1 else 0;
        const eol = std.mem.indexOf(u8, text[slice_start..], "\n");
        const line = text[slice_start .. if (eol) |e| slice_start + e else text.len];
        try std.testing.expect(std.mem.indexOf(u8, line, "method=") == null);
        try std.testing.expect(std.mem.indexOf(u8, line, "path=") == null);
        // And the only label is kind.
        try std.testing.expect(std.mem.indexOf(u8, line, "kind=") != null);
    } else {
        try std.testing.expect(false); // line must exist
    }
}

test "metrics: empty registry renders new epub + pi families at zero" {
    var m = Metrics.init(0);
    defer m.deinit(std.testing.allocator);

    const text = try m.render(std.testing.allocator, 0);
    defer std.testing.allocator.free(text);

    // EPUB-generated counter: both kinds at zero with HELP/TYPE.
    try std.testing.expect(std.mem.indexOf(u8, text, "# TYPE curation_epub_generations_total counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_epub_generations_total{kind=\"news\"} 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_epub_generations_total{kind=\"knowledge\"} 0") != null);

    // pi-evaluation counters at zero.
    try std.testing.expect(std.mem.indexOf(u8, text, "# TYPE curation_pi_evaluations_total counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluations_total 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "# TYPE curation_pi_evaluations_failed_total counter") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluations_failed_total 0") != null);

    // pi-evaluation histogram at zero with HELP/TYPE and +Inf bucket.
    try std.testing.expect(std.mem.indexOf(u8, text, "# TYPE curation_pi_evaluation_duration_seconds histogram") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluation_duration_seconds_bucket") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "le=\"+Inf\"} 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluation_duration_seconds_count 0") != null);
}

test "metrics: recordEpubGeneration increments the per-kind counter and renders it" {
    var m = Metrics.init(0);
    defer m.deinit(std.testing.allocator);

    m.recordEpubGeneration(.news);
    m.recordEpubGeneration(.news);
    m.recordEpubGeneration(.knowledge);

    const text = try m.render(std.testing.allocator, 0);
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "curation_epub_generations_total{kind=\"news\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_epub_generations_total{kind=\"knowledge\"} 1") != null);
}

test "metrics: recordPiEval increments counters and adds a latency sample" {
    var m = Metrics.init(0);
    defer m.deinit(std.testing.allocator);

    // 0.25s sample → bucket 0.25.
    try m.recordPiEval(std.testing.allocator, 250_000_000, false);
    // 0.005s sample → bucket 0.005.
    try m.recordPiEval(std.testing.allocator, 5_000_000, true);

    const text = try m.render(std.testing.allocator, 0);
    defer std.testing.allocator.free(text);

    // Counters.
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluations_total 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluations_failed_total 1") != null);

    // Histogram _count is 2; both samples land in some bucket.
    try std.testing.expect(std.mem.indexOf(u8, text, "curation_pi_evaluation_duration_seconds_count 2") != null);
    // +Inf bucket shows the cumulative count of 2.
    try std.testing.expect(std.mem.indexOf(u8, text, "le=\"+Inf\"} 2") != null);
    // 0.005 second bucket holds at least one sample (the 5ms one).
    try std.testing.expect(std.mem.indexOf(u8, text, "le=\"0.005\"} 1") != null);
    // 0.25 second bucket holds at least one sample (the 250ms one).
    try std.testing.expect(std.mem.indexOf(u8, text, "le=\"0.25\"} 2") != null);
}

test "metrics: pi evaluation histogram has no method/path/kind label" {
    var m = Metrics.init(0);
    defer m.deinit(std.testing.allocator);

    try m.recordPiEval(std.testing.allocator, 1_000_000, false);
    const text = try m.render(std.testing.allocator, 0);
    defer std.testing.allocator.free(text);

    // pi-evaluation histogram lines must not carry method=/path=/kind= labels.
    if (std.mem.indexOf(u8, text, "curation_pi_evaluation_duration_seconds_bucket{")) |idx| {
        const line_start = std.mem.lastIndexOf(u8, text[0..idx], "\n");
        const slice_start = if (line_start) |ls| ls + 1 else 0;
        const eol = std.mem.indexOf(u8, text[slice_start..], "\n");
        const line = text[slice_start .. if (eol) |e| slice_start + e else text.len];
        try std.testing.expect(std.mem.indexOf(u8, line, "method=") == null);
        try std.testing.expect(std.mem.indexOf(u8, line, "path=") == null);
        try std.testing.expect(std.mem.indexOf(u8, line, "kind=") == null);
    } else {
        try std.testing.expect(false); // bucket line must exist
    }
}
