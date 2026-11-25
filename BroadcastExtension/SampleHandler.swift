import ReplayKit

/// Runs while any app is on screen: streams CoreMotion (UDP) and the encoded screen (TCP) to the Mac.
class SampleHandler: RPBroadcastSampleHandler {
    private var streamer: TelemetryStreamer?
    private var videoLink: VideoLink?
    private var encoder: VideoEncoder?
    private let encodeQueue = DispatchQueue(label: "projector.encode", qos: .userInteractive)
    private let pendingLock = NSLock()
    private var pending = 0
    private var droppedQueueFull = 0
    private var heartbeat: DispatchSourceTimer?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let link = VideoLink()
        videoLink = link
        encoder = VideoEncoder(link: link)

        let s = TelemetryStreamer(source: .broadcast)
        s.link.onVideoEndpoint = { [weak link] e in link?.connect(to: e) }
        link.log = { [weak s] msg in s?.link.log(msg) }
        s.start()
        streamer = s

        // Heartbeat into the Mac's log: the only window we have into this process.
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "projector.heartbeat"))
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self, weak s] in
            guard let self, let s, let enc = self.encoder, let link = self.videoLink else { return }
            let c = enc.countersSnapshot()
            let qf = self.pendingLock.withLock { self.droppedQueueFull }
            s.link.log("hb codec=\(enc.codec) tcp=\(link.isReady ? "ready" : "down") inflight=\(link.inflightBytes) calls=\(c.encodeCalls) notReady=\(c.notReady) out=\(c.outputs) sent=\(c.sent) keys=\(c.keyframes) dropBP=\(c.droppedBackpressure) dropKey=\(c.droppedWaitingKey) dropQ=\(qf) err=\(c.encodeErrors) lastErr=\(c.lastError) sessions=\(c.sessionsCreated) mem=\(String(format: "%.1f", DeviceInfo.memoryFootprintMB()))MB")
        }
        t.resume()
        heartbeat = t
    }

    override func broadcastFinished() {
        heartbeat?.cancel(); heartbeat = nil
        streamer?.stop(); streamer = nil
        encodeQueue.sync { encoder?.invalidate() }
        encoder = nil
        videoLink?.stop(); videoLink = nil
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video else { return }
        streamer?.countVideoFrame()
        // ReplayKit buffers arrive in the panel's native portrait orientation, which is exactly
        // what the physical screen of the 3D model shows — no rotation needed.
        // Never queue more than two frames: holding ReplayKit buffers is the fastest way to hit the memory limit.
        let accept = pendingLock.withLock { () -> Bool in
            guard pending < 2 else { droppedQueueFull += 1; return false }
            pending += 1; return true
        }
        guard accept else { return }
        encodeQueue.async { [weak self, encoder] in
            encoder?.encode(sampleBuffer)
            self?.pendingLock.withLock { self?.pending -= 1 }
        }
    }
}
