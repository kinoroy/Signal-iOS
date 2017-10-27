//
//  Copyright (c) 2017 Open Whisper Systems. All rights reserved.
//

import Foundation
import ObjectiveC

// Stills should be loaded before full GIFs.
enum GiphyRequestPriority {
    case low, high
}

enum GiphyAssetSegmentState: UInt {
    case waiting
    case active
    case complete
    case failed
}

class GiphyAssetSegment {
    let TAG = "[GiphyAssetSegment]"

    public let index: UInt
    public let segmentStart: UInt
    public let segmentLength: UInt
    public let redundantLength: UInt
    public var state: GiphyAssetSegmentState = .waiting
    private var datas = [Data]()

    init(index: UInt,
         segmentStart: UInt,
         segmentLength: UInt,
         redundantLength: UInt) {
        self.index = index
        self.segmentStart = segmentStart
        self.segmentLength = segmentLength
        self.redundantLength = redundantLength
    }

    public func totalDataSize() -> UInt {
        var result: UInt = 0
        for data in datas {
            result += UInt(data.count)
        }
        return result
    }

    public func append(data: Data) {
        datas.append(data)
    }

    public func mergeData(assetData: NSMutableData) {
        // In some cases the last two segments will overlap.
        // In that case, we only want to append the non-overlapping
        // tail of the last segment.
        var bytesToIgnore = Int(redundantLength)
        for data in datas {
            if data.count <= bytesToIgnore {
                bytesToIgnore -= data.count
            } else if bytesToIgnore > 0 {
                let range = NSMakeRange(bytesToIgnore, data.count - bytesToIgnore)
                Logger.verbose("\(TAG) bytesToIgnore: \(bytesToIgnore), data.count: \(data.count), range: \(range.location), \(range.length).")
                let subdata = (data as NSData).subdata(with: range)
                Logger.verbose("\(TAG) subdata: \(subdata.count).")
                assetData.append(subdata)
                bytesToIgnore = 0
            } else {
                assetData.append(data)
            }
        }
    }
}

enum GiphyAssetRequestState: UInt {
    case waiting
    case requestingSize
    case active
    case complete
    case failed
}

// Represents a request to download a GIF.
//
// Should be cancelled if no longer necessary.
@objc class GiphyAssetRequest: NSObject {
    static let TAG = "[GiphyAssetRequest]"
    let TAG = "[GiphyAssetRequest]"

    let rendition: GiphyRendition
    let priority: GiphyRequestPriority
    // Exactly one of success or failure should be called once,
    // on the main thread _unless_ this request is cancelled before
    // the request succeeds or fails.
    private var success: ((GiphyAssetRequest?, GiphyAsset) -> Void)?
    private var failure: ((GiphyAssetRequest) -> Void)?

    var wasCancelled = false
    // This property is an internal implementation detail of the download process.
    var assetFilePath: String?

    private var segments = [GiphyAssetSegment]()
    private var assetData = NSMutableData()
    public var state: GiphyAssetRequestState = .waiting
    public var contentLength: Int = 0 {
        didSet {
            AssertIsOnMainThread()
            assert(oldValue == 0)
            assert(contentLength > 0)

            createSegments()
        }
    }

    init(rendition: GiphyRendition,
         priority: GiphyRequestPriority,
         success:@escaping ((GiphyAssetRequest?, GiphyAsset) -> Void),
         failure:@escaping ((GiphyAssetRequest) -> Void)) {
        self.rendition = rendition
        self.priority = priority
        self.success = success
        self.failure = failure

        super.init()
    }

    private func segmentSize() -> UInt {
        let fileSize = UInt(contentLength)
        guard fileSize > 0 else {
            owsFail("\(TAG) rendition missing filesize")
            requestDidFail()
            return 0
        }

        let k1MB: UInt = 1024 * 1024
        let k500KB: UInt = 500 * 1024
        let k100KB: UInt = 100 * 1024
        let k50KB: UInt = 50 * 1024
        let k10KB: UInt = 10 * 1024
        let k1KB: UInt = 1 * 1024
        for segmentSize in [k1MB, k500KB, k100KB, k50KB, k10KB, k1KB ] {
            if fileSize >= segmentSize {
                return segmentSize
            }
        }
        return fileSize
    }

    private func createSegments() {
        let segmentLength = segmentSize()
        guard segmentLength > 0 else {
            return
        }
        let fileSize = UInt(contentLength)

        var nextSegmentStart: UInt = 0
        var index: UInt = 0
        while nextSegmentStart < fileSize {
            var segmentStart: UInt = nextSegmentStart
            var redundantLength: UInt = 0
            // The last segment may overlap the penultimate segment
            // in order to keep the segment sizes uniform.
            if segmentStart + segmentLength > fileSize {
                redundantLength = segmentStart + segmentLength - fileSize
                segmentStart = fileSize - segmentLength
            }
            segments.append(GiphyAssetSegment(index:index,
                                              segmentStart:segmentStart,
                                              segmentLength:segmentLength,
                                              redundantLength:redundantLength))
            nextSegmentStart = segmentStart + segmentLength
            index += 1
        }
    }

    private func firstSegmentWithState(state: GiphyAssetSegmentState) -> GiphyAssetSegment? {
        for segment in segments {
            guard segment.state != .failed else {
                owsFail("\(TAG) unexpected failed segment.")
                continue
            }
            if segment.state == state {
                return segment
            }
        }
        return nil
    }

    public func firstWaitingSegment() -> GiphyAssetSegment? {
        return firstSegmentWithState(state:.waiting)
    }

    public func firstActiveSegment() -> GiphyAssetSegment? {
        return firstSegmentWithState(state:.active)
    }

    public func mergeSegmentData(segment: GiphyAssetSegment) {
        guard segment.totalDataSize() > 0 else {
            owsFail("\(TAG) could not merge empty segment.")
            return
        }
        guard segment.state == .complete else {
            owsFail("\(TAG) could not merge incomplete segment.")
            return
        }
        Logger.verbose("\(TAG) merging segment: \(segment.index) \(segment.segmentStart) \(segment.segmentLength) \(segment.redundantLength) \(rendition.url).")
        Logger.verbose("\(TAG) before merge: \(assetData.length) \(rendition.url).")
        segment.mergeData(assetData: assetData)
        Logger.verbose("\(TAG) after merge: \(assetData.length) \(rendition.url).")
    }

    public func writeAssetToFile(gifFolderPath: String) -> GiphyAsset? {
        guard assetData.length == contentLength else {
            owsFail("\(TAG) asset data has unexpected length.")
            return nil
        }

        guard assetData.length > 0 else {
            owsFail("\(TAG) could not write empty asset to disk.")
            return nil
        }

        let fileExtension = rendition.fileExtension
        let fileName = (NSUUID().uuidString as NSString).appendingPathExtension(fileExtension)!
        let filePath = (gifFolderPath as NSString).appendingPathComponent(fileName)

        Logger.verbose("\(TAG) filePath: \(filePath).")

        let success = assetData.write(toFile: filePath, atomically: true)
        guard success else {
            owsFail("\(TAG) could not write asset to disk.")
            return nil
        }
        let asset = GiphyAsset(rendition: rendition, filePath : filePath)
        return asset
    }

    public func cancel() {
        AssertIsOnMainThread()

        wasCancelled = true

        // Don't call the callbacks if the request is cancelled.
        clearCallbacks()
    }

    private func clearCallbacks() {
        AssertIsOnMainThread()

        success = nil
        failure = nil
    }

    public func requestDidSucceed(asset: GiphyAsset) {
        AssertIsOnMainThread()

        success?(self, asset)

        // Only one of the callbacks should be called, and only once.
        clearCallbacks()
    }

    public func requestDidFail() {
        AssertIsOnMainThread()

        failure?(self)

        // Only one of the callbacks should be called, and only once.
        clearCallbacks()
    }
}

// Represents a downloaded gif asset.
//
// The blob on disk is cleaned up when this instance is deallocated,
// so consumers of this resource should retain a strong reference to
// this instance as long as they are using the asset.
@objc class GiphyAsset: NSObject {
    static let TAG = "[GiphyAsset]"

    let rendition: GiphyRendition
    let filePath: String

    init(rendition: GiphyRendition,
         filePath: String) {
        self.rendition = rendition
        self.filePath = filePath
    }

    deinit {
        // Clean up on the asset on disk.
        let filePathCopy = filePath
        DispatchQueue.global().async {
            do {
                let fileManager = FileManager.default
                try fileManager.removeItem(atPath:filePathCopy)
            } catch let error as NSError {
                owsFail("\(GiphyAsset.TAG) file cleanup failed: \(filePathCopy), \(error)")
            }
        }
    }
}

// A simple LRU cache bounded by the number of entries.
class LRUCache<KeyType: Hashable & Equatable, ValueType> {

    private var cacheMap = [KeyType: ValueType]()
    private var cacheOrder = [KeyType]()
    private let maxSize: Int

    init(maxSize: Int) {
        self.maxSize = maxSize
    }

    public func get(key: KeyType) -> ValueType? {
        guard let value = cacheMap[key] else {
            return nil
        }

        // Update cache order.
        cacheOrder = cacheOrder.filter { $0 != key }
        cacheOrder.append(key)

        return value
    }

    public func set(key: KeyType, value: ValueType) {
        cacheMap[key] = value

        // Update cache order.
        cacheOrder = cacheOrder.filter { $0 != key }
        cacheOrder.append(key)

        while cacheOrder.count > maxSize {
            guard let staleKey = cacheOrder.first else {
                owsFail("Cache ordering unexpectedly empty")
                return
            }
            cacheOrder.removeFirst()
            cacheMap.removeValue(forKey:staleKey)
        }
    }
}

private var URLSessionTaskGiphyAssetRequest: UInt8 = 0
private var URLSessionTaskGiphyAssetSegment: UInt8 = 0

// This extension is used to punch an asset request onto a download task.
extension URLSessionTask {
    var assetRequest: GiphyAssetRequest {
        get {
            return objc_getAssociatedObject(self, &URLSessionTaskGiphyAssetRequest) as! GiphyAssetRequest
        }
        set {
            objc_setAssociatedObject(self, &URLSessionTaskGiphyAssetRequest, newValue, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    var assetSegment: GiphyAssetSegment {
        get {
            return objc_getAssociatedObject(self, &URLSessionTaskGiphyAssetSegment) as! GiphyAssetSegment
        }
        set {
            objc_setAssociatedObject(self, &URLSessionTaskGiphyAssetSegment, newValue, objc_AssociationPolicy.OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
}

@objc class GiphyDownloader: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {

    // MARK: - Properties

    let TAG = "[GiphyDownloader]"

    static let sharedInstance = GiphyDownloader()

    // A private queue used for download task callbacks.
    private let operationQueue = OperationQueue()

    var gifFolderPath = ""

    // Force usage as a singleton
    override private init() {
        AssertIsOnMainThread()

        super.init()

        ensureGifFolder()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private let kGiphyBaseURL = "https://api.giphy.com/"

    private func giphyDownloadSession() -> URLSession? {
        let configuration = GiphyAPI.giphySessionConfiguration()
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringCacheData
        let session = URLSession(configuration:configuration,
                                 delegate:self, delegateQueue:operationQueue)
        return session
    }

    // 100 entries of which at least half will probably be stills.
    // Actual animated GIFs will usually be less than 3 MB so the
    // max size of the cache on disk should be ~150 MB.  Bear in mind
    // that assets are not always deleted on disk as soon as they are
    // evacuated from the cache; if a cache consumer (e.g. view) is
    // still using the asset, the asset won't be deleted on disk until
    // it is no longer in use.
    private var assetMap = LRUCache<NSURL, GiphyAsset>(maxSize:100)
    // TODO: We could use a proper queue, e.g. implemented with a linked
    // list.
    private var assetRequestQueue = [GiphyAssetRequest]()
    private let kMaxAssetRequestCount = 3
//    private var activeAssetRequests = Set<GiphyAssetRequest>()

    // The success and failure callbacks are always called on main queue.
    //
    // The success callbacks may be called synchronously on cache hit, in
    // which case the GiphyAssetRequest parameter will be nil.
    public func requestAsset(rendition: GiphyRendition,
                             priority: GiphyRequestPriority,
                             success:@escaping ((GiphyAssetRequest?, GiphyAsset) -> Void),
                             failure:@escaping ((GiphyAssetRequest) -> Void)) -> GiphyAssetRequest? {
        AssertIsOnMainThread()

        if let asset = assetMap.get(key:rendition.url) {
            // Synchronous cache hit.
            success(nil, asset)
            return nil
        }

        // Cache miss.
        //
        // Asset requests are done queued and performed asynchronously.
        let assetRequest = GiphyAssetRequest(rendition:rendition,
                                             priority:priority,
                                             success:success,
                                             failure:failure)
        assetRequestQueue.append(assetRequest)
        processRequestQueue()
        return assetRequest
    }

    public func cancelAllRequests() {
        AssertIsOnMainThread()

        self.assetRequestQueue.forEach { $0.cancel() }
        self.assetRequestQueue = []
    }

    private func segmentRequestDidSucceed(assetRequest: GiphyAssetRequest, assetSegment: GiphyAssetSegment) {
        Logger.verbose("\(self.TAG) segment request succeeded \(assetRequest.rendition.url), \(assetSegment.index), \(assetSegment.segmentStart), \(assetSegment.segmentLength)")

        DispatchQueue.main.async {
            assetSegment.state = .complete
            // TODO: Should we move this merge off main thread?
            assetRequest.mergeSegmentData(segment : assetSegment)

            // If the asset request has completed all of its segments,
            // try to write the asset to file.
            if assetRequest.firstWaitingSegment() == nil {
                assetRequest.state = .complete

                // Move write off main thread.
                DispatchQueue.global().async {
                    guard let asset = assetRequest.writeAssetToFile(gifFolderPath:self.gifFolderPath) else {
                        self.segmentRequestDidFail(assetRequest:assetRequest, assetSegment:assetSegment)
                        return
                    }
                    self.assetRequestDidSucceed(assetRequest: assetRequest, asset: asset)
                }
            } else {
                self.processRequestQueue()
            }
        }
    }

    private func assetRequestDidSucceed(assetRequest: GiphyAssetRequest, asset: GiphyAsset) {
        Logger.verbose("\(self.TAG) asset request succeeded \(assetRequest.rendition.url)")

        DispatchQueue.main.async {
            self.assetMap.set(key:assetRequest.rendition.url, value:asset)
            self.removeAssetRequestFromQueue(assetRequest:assetRequest)
            assetRequest.requestDidSucceed(asset:asset)
            self.processRequestQueue()
        }
    }

    // TODO: If we wanted to implement segment retry, we'll need to add
    //       a segmentRequestDidFail() method.
    private func segmentRequestDidFail(assetRequest: GiphyAssetRequest, assetSegment: GiphyAssetSegment) {
        Logger.verbose("\(self.TAG) segment request failed \(assetRequest.rendition.url), \(assetSegment.index), \(assetSegment.segmentStart), \(assetSegment.segmentLength)")

        DispatchQueue.main.async {
            assetSegment.state = .failed
            assetRequest.state = .failed
            self.assetRequestDidFail(assetRequest:assetRequest)
        }
    }

    private func assetRequestDidFail(assetRequest: GiphyAssetRequest) {
        Logger.verbose("\(self.TAG) asset request failed \(assetRequest.rendition.url)")

        DispatchQueue.main.async {
            self.removeAssetRequestFromQueue(assetRequest:assetRequest)
            assetRequest.requestDidFail()
            self.processRequestQueue()
        }
    }

    private func removeAssetRequestFromQueue(assetRequest: GiphyAssetRequest) {
        AssertIsOnMainThread()

        guard assetRequestQueue.contains(assetRequest) else {
            Logger.warn("\(TAG) could not remove asset request from queue: \(assetRequest.rendition.url)")
            return
        }

        assetRequestQueue = assetRequestQueue.filter { $0 != assetRequest }
    }

    // Start a request if necessary, complete asset requests if possible.
    private func processRequestQueue() {
        AssertIsOnMainThread()

        DispatchQueue.main.async {
            guard let assetRequest = self.popNextAssetRequest() else {
                return
            }
            guard !assetRequest.wasCancelled else {
                // Discard the cancelled asset request and try again.
                self.processRequestQueue()
                return
            }
            guard UIApplication.shared.applicationState == .active else {
                // If app is not active, fail the asset request.
                assetRequest.state = .failed
                self.assetRequestDidFail(assetRequest:assetRequest)
                self.processRequestQueue()
                return
            }

            if let asset = self.assetMap.get(key:assetRequest.rendition.url) {
                // Deferred cache hit, avoids re-downloading assets that were
                // downloaded while this request was queued.

                assetRequest.state = .complete
                self.assetRequestDidSucceed(assetRequest : assetRequest, asset: asset)
                return
            }

            guard let downloadSession = self.giphyDownloadSession() else {
                owsFail("\(self.TAG) Couldn't create session manager.")
                assetRequest.state = .failed
                self.assetRequestDidFail(assetRequest:assetRequest)
                return
            }

            if assetRequest.state == .waiting {
                // If asset request hasn't yet determined the resource size,
                // try to do so now.
                assetRequest.state = .requestingSize

                var request = URLRequest(url: assetRequest.rendition.url as URL)
                request.httpMethod = "HEAD"

                let task = downloadSession.dataTask(with:request, completionHandler: { [weak self] _, response, error -> Void in
                    self?.handleAssetSizeResponse(assetRequest:assetRequest, response:response, error:error)
                })

                task.resume()
                return
            }

            // Start a download task.

            guard let assetSegment = assetRequest.firstWaitingSegment() else {
                owsFail("\(self.TAG) queued asset request does not have a waiting segment.")
                return
            }
            assetSegment.state = .active
            assetRequest.state = .active

            Logger.verbose("\(self.TAG) new segment request \(assetRequest.rendition.url), \(assetSegment.index), \(assetSegment.segmentStart), \(assetSegment.segmentLength)")

            var request = URLRequest(url: assetRequest.rendition.url as URL)
            let rangeHeaderValue = "bytes=\(assetSegment.segmentStart)-\(assetSegment.segmentStart + assetSegment.segmentLength - 1)"
            Logger.verbose("\(self.TAG) rangeHeaderValue: \(rangeHeaderValue)")
            request.addValue(rangeHeaderValue, forHTTPHeaderField: "Range")
            let task = downloadSession.dataTask(with:request)
            task.assetRequest = assetRequest
            task.assetSegment = assetSegment
            task.resume()
        }
    }

    private func handleAssetSizeResponse(assetRequest: GiphyAssetRequest, response: URLResponse?, error: Error?) {
        guard let httpResponse = response as? HTTPURLResponse else {
            owsFail("\(self.TAG) Asset size response is invalid.")
            assetRequest.state = .failed
            self.assetRequestDidFail(assetRequest:assetRequest)
            return
        }
        guard let contentLengthString = httpResponse.allHeaderFields["Content-Length"] as? String else {
            owsFail("\(self.TAG) Asset size response is missing content length.")
            assetRequest.state = .failed
            self.assetRequestDidFail(assetRequest:assetRequest)
            return
        }
        guard let contentLength = Int(contentLengthString) else {
            owsFail("\(self.TAG) Asset size response has unparsable content length.")
            assetRequest.state = .failed
            self.assetRequestDidFail(assetRequest:assetRequest)
            return
        }
        guard contentLength > 0 else {
            owsFail("\(self.TAG) Asset size response has invalid content length.")
            assetRequest.state = .failed
            self.assetRequestDidFail(assetRequest:assetRequest)
            return
        }

        DispatchQueue.main.async {
            assetRequest.contentLength = contentLength
            assetRequest.state = .active
            self.processRequestQueue()
        }
    }

    private func popNextAssetRequest() -> GiphyAssetRequest? {
        AssertIsOnMainThread()

        // Prefer the first "high" priority request;
        // fall back to the first "low" priority request.
        var activeAssetRequestsCount = 0
        for priority in [GiphyRequestPriority.high, GiphyRequestPriority.low] {
            for assetRequest in assetRequestQueue where assetRequest.priority == priority {
                switch assetRequest.state {
                case .waiting:
                    break
                case .requestingSize:
                    activeAssetRequestsCount += 1
                    continue
                case .active:
                    break
                case .complete:
                    continue
                case .failed:
                    continue
                }

                guard assetRequest.firstActiveSegment() == nil else {
                    activeAssetRequestsCount += 1
                    // Ensure that only N requests are active at a time.
                    guard activeAssetRequestsCount < self.kMaxAssetRequestCount else {
                        return nil
                    }

                    continue
                }
                return assetRequest
            }
        }

        return nil
    }

    // MARK: URLSessionDataDelegate

    @nonobjc
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {

        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let assetRequest = dataTask.assetRequest
        let assetSegment = dataTask.assetSegment
        Logger.verbose("\(TAG) session dataTask didReceive: \(data.count) \(assetRequest.rendition.url)")
        guard !assetRequest.wasCancelled else {
            dataTask.cancel()
            segmentRequestDidFail(assetRequest:assetRequest, assetSegment:assetSegment)
            return
        }
        assetSegment.append(data:data)
    }

    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, willCacheResponse proposedResponse: CachedURLResponse, completionHandler: @escaping (CachedURLResponse?) -> Swift.Void) {
        completionHandler(nil)
    }

    // MARK: URLSessionTaskDelegate

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
//        owsFail("\(TAG) session task didCompleteWithError \(error)")
        Logger.verbose("\(TAG) session task didCompleteWithError \(error)")

        let assetRequest = task.assetRequest
        let assetSegment = task.assetSegment
        guard !assetRequest.wasCancelled else {
            task.cancel()
            segmentRequestDidFail(assetRequest:assetRequest, assetSegment:assetSegment)
            return
        }
        if let error = error {
            Logger.error("\(TAG) download failed with error: \(error)")
            segmentRequestDidFail(assetRequest:assetRequest, assetSegment:assetSegment)
            return
        }
        guard let httpResponse = task.response as? HTTPURLResponse else {
            Logger.error("\(TAG) missing or unexpected response: \(task.response)")
            segmentRequestDidFail(assetRequest:assetRequest, assetSegment:assetSegment)
            return
        }
        let statusCode = httpResponse.statusCode
        guard statusCode >= 200 && statusCode < 400 else {
            Logger.error("\(TAG) response has invalid status code: \(statusCode)")
            segmentRequestDidFail(assetRequest:assetRequest, assetSegment:assetSegment)
            return
        }
        guard assetSegment.totalDataSize() == assetSegment.segmentLength else {
            Logger.error("\(TAG) segment is missing data: \(statusCode)")
            segmentRequestDidFail(assetRequest:assetRequest, assetSegment:assetSegment)
            return
        }

        segmentRequestDidSucceed(assetRequest : assetRequest, assetSegment: assetSegment)
    }

    // MARK: Temp Directory

    public func ensureGifFolder() {
        // We write assets to the temporary directory so that iOS can clean them up.
        // We try to eagerly clean up these assets when they are no longer in use.

        let tempDirPath = NSTemporaryDirectory()
        let dirPath = (tempDirPath as NSString).appendingPathComponent("GIFs")
        do {
            let fileManager = FileManager.default

            // Try to delete existing folder if necessary.
            if fileManager.fileExists(atPath:dirPath) {
                try fileManager.removeItem(atPath:dirPath)
                gifFolderPath = dirPath
            }
            // Try to create folder if necessary.
            if !fileManager.fileExists(atPath:dirPath) {
                try fileManager.createDirectory(atPath:dirPath,
                                                withIntermediateDirectories:true,
                                                attributes:nil)
                gifFolderPath = dirPath
            }
        } catch let error as NSError {
            owsFail("\(GiphyAsset.TAG) ensureTempFolder failed: \(dirPath), \(error)")
            gifFolderPath = tempDirPath
        }
    }
}
