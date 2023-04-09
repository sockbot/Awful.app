//  ForumsClient.swift
//
//  Copyright 2017 Awful Contributors. CC BY-NC-SA 3.0 US https://github.com/Awful/Awful.app

import AwfulScraping
import CoreData
import Foundation
import HTMLReader
import PromiseKit

/// Sends data to and scrapes data from the Something Awful Forums.
public final class ForumsClient {
    private var urlSession: ForumsURLSession?
    private var backgroundManagedObjectContext: NSManagedObjectContext?
    private var lastModifiedObserver: LastModifiedContextObserver?

    private let scrapingQueue = DispatchQueue(label: "com.awfulapp.ForumsClient.Scraping")

    /// A block to call when the login session is destroyed. Not called when logging out from Awful.
    public var didRemotelyLogOut: (() -> Void)?

    /// Convenient singleton.
    public static let shared = ForumsClient()
    private init() {}
    
    public typealias CancellablePromise<T> = (promise: Promise<T>, cancellable: Cancellable)

    /**
     The Forums endpoint for the client. Typically https://forums.somethingawful.com

     Setting a new baseURL cancels all in-flight requests.
     */
    public var baseURL: URL? {
        didSet {
            guard oldValue != baseURL else { return }
            urlSession = baseURL.map(ForumsURLSession.init)
        }
    }

    /// A managed object context into which data is imported after scraping.
    public var managedObjectContext: NSManagedObjectContext? {
        didSet {
            if let oldValue = oldValue {
                NotificationCenter.default.removeObserver(self, name: .NSManagedObjectContextDidSave, object: oldValue)
            }
            if let oldBackground = backgroundManagedObjectContext {
                NotificationCenter.default.removeObserver(self, name: .NSManagedObjectContextDidSave, object: oldBackground)
                backgroundManagedObjectContext = nil
                lastModifiedObserver = nil
            }
            
            guard let newValue = managedObjectContext else { return }

            NotificationCenter.default.addObserver(self, selector: #selector(mainManagedObjectContextDidSave), name: .NSManagedObjectContextDidSave, object: newValue)

            let background = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            backgroundManagedObjectContext = background
            background.persistentStoreCoordinator = newValue.persistentStoreCoordinator
            NotificationCenter.default.addObserver(self, selector: #selector(backgroundManagedObjectContextDidSave), name: .NSManagedObjectContextDidSave, object: background)

            lastModifiedObserver = LastModifiedContextObserver(managedObjectContext: background)
        }
    }

    @objc private func mainManagedObjectContextDidSave(_ notification: Notification) {
        guard let context = backgroundManagedObjectContext else { return }
        context.perform { context.mergeChanges(fromContextDidSave: notification) }
    }

    @objc private func backgroundManagedObjectContextDidSave(_ notification: Notification) {
        guard let context = managedObjectContext else { return }

        let updatedObjectIDs: [NSManagedObjectID] = {
            guard
                let userInfo = notification.userInfo,
                let updatedObjects = userInfo[NSUpdatedObjectsKey] as? Set<NSManagedObject>
                else { return [] }
            return updatedObjects.map { $0.objectID }
        }()

        context.perform {
            updatedObjectIDs
                .compactMap { context.object(with: $0) }
                .forEach { $0.willAccessValue(forKey: nil) }
            
            context.mergeChanges(fromContextDidSave: notification)
        }
    }

    private var loginCookie: HTTPCookie? {
        return baseURL
            .flatMap { urlSession?.httpCookieStorage?.cookies(for: $0) }?
            .first { $0.name == "bbuserid" }
    }

    /// Whether or not a valid, logged-in session exists.
    public var isLoggedIn: Bool {
        return loginCookie != nil
    }
    
    public var awfulUserAgent: String {
        let info = Bundle.main.infoDictionary!
        let executable = info[kCFBundleExecutableKey as String] as? String ?? "Unknown"
        let bundle = info[kCFBundleIdentifierKey as String] as? String ?? "Unknown"
        let appVersion = info["CFBundleShortVersionString"] as? String ?? "Unknown"
        let appBuild = info[kCFBundleVersionKey as String] as? String ?? "Unknown"
        
        let osNameVersion: String = {
            let version = ProcessInfo.processInfo.operatingSystemVersion
            let versionString = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
            
            let osName: String = {
                #if os(iOS)
                    return "iOS"
                #elseif os(watchOS)
                    return "watchOS"
                #elseif os(tvOS)
                    return "tvOS"
                #elseif os(macOS)
                    return "OS X"
                #elseif os(Linux)
                    return "Linux"
                #else
                    return "Unknown"
                #endif
            }()
            
            return "\(osName) \(versionString)"
        }()
        
        return "\(executable)/\(appVersion) (\(bundle); build:\(appBuild); \(osNameVersion))"
    }

    /// When the valid, logged-in session expires.
    public var loginCookieExpiryDate: Date? {
        return loginCookie?.expiresDate
    }

    enum PromiseError: Error {
        case failedTransferToMainContext
        case missingURLSession
        case invalidBaseURL
        case missingDataAndError
        case missingManagedObjectContext
        case requestSerializationError(String)
        case unexpectedContentType(String, expected: String)
    }

    private func fetch<S>(
        method: ForumsURLSession.Method,
        urlString: String,
        parameters: S?,
        redirectBlock: ForumsURLSession.WillRedirectCallback? = nil
    ) -> (promise: ForumsURLSession.PromiseType, cancellable: Cancellable) where S: Sequence, S.Element == KeyValuePairs<String, Any>.Element {
        guard let urlSession = urlSession else {
            return (Promise(error: PromiseError.missingURLSession), Operation())
        }

        let wasLoggedIn = isLoggedIn

        let tuple = urlSession.fetch(method: method, urlString: urlString, parameters: parameters, redirectBlock: redirectBlock)

        _ = tuple.promise.done { data, response in
            if wasLoggedIn, !self.isLoggedIn, let block = self.didRemotelyLogOut {
                DispatchQueue.main.async(execute: block)
            }
        }

        return tuple
    }

    // MARK: Forums Session

    public func logIn(username: String, password: String) -> Promise<User> {
        guard
            let backgroundContext = backgroundManagedObjectContext,
            let mainContext = managedObjectContext else
        {
            return Promise(error: PromiseError.missingManagedObjectContext)
        }

        // Not that we'll parse any JSON from the login attempt, but it might avoid pointless server-side rendering.
        let urlString = "account.php?json=1"

        let parameters: Dictionary<String, Any> = [
            "action": "login",
            "username": username,
            "password" : password,
            "next": "/index.php?json=1"]

        return fetch(method: .post, urlString: urlString, parameters: parameters)
            .promise
            .decode(as: IndexScrapeResult.self, on: scrapingQueue)
            .map(on: backgroundContext) { scrapeResult, context -> NSManagedObjectID in
                let result = try scrapeResult.upsert(into: context)
                try context.save()
                return result.currentUser.objectID
            }
            .map(on: mainContext) { objectID, context in
                guard let user = context.object(with: objectID) as? User else {
                    throw PromiseError.failedTransferToMainContext
                }
                return user
        }
    }

    // MARK: Forums

    public func taxonomizeForums() -> Promise<Void> {
        guard let backgroundContext = backgroundManagedObjectContext else {
            return Promise(error: PromiseError.missingManagedObjectContext)
        }

        // Seems like only `forumdisplay.php` and `showthread.php` have the `<select>` with a complete list of forums. We'll use the Main "forum" as it's the smallest page with the drop-down list.
        return fetch(method: .get, urlString: "index.php?json=1", parameters: [])
            .promise
            .decode(as: IndexScrapeResult.self, on: scrapingQueue)
            .map(on: backgroundContext) { scrapeResult, context -> Void in
                try scrapeResult.upsert(into: context)
                try context.save()
            }
    }

    // MARK: Threads

    /// - Parameter tagged: A thread tag to use for filtering forums, or `nil` for no filtering.
    public func listThreads(in forum: Forum, tagged threadTag: ThreadTag?, page: Int) -> Promise<[AwfulThread]> {
        guard
            let backgroundContext = backgroundManagedObjectContext,
            let mainContext = managedObjectContext else
        {
            return Promise(error: PromiseError.missingManagedObjectContext)
        }

        var parameters: Dictionary<String, Any> = [
            "forumid": forum.forumID,
            "perpage": "40",
            "pagenumber": "\(page)"]
        if let threadTagID = threadTag?.threadTagID, !threadTagID.isEmpty {
            parameters["posticon"] = threadTagID
        }

        return fetch(method: .get, urlString: "forumdisplay.php", parameters: parameters).promise
            .scrape(as: ThreadListScrapeResult.self, on: scrapingQueue)
            .map(on: backgroundContext) { result, context -> [NSManagedObjectID] in
                let threads = try result.upsert(into: context)
                _ = try result.upsertAnnouncements(into: context)
                
                forum.canPost = result.canPostNewThread
                
                if
                    page == 1,
                    var threadsToForget = threads.first?.forum?.threads
                {
                    threadsToForget.subtract(threads)
                    threadsToForget.forEach { $0.threadListPage = 0 }
                }

                try context.save()

                return threads.map { $0.objectID }
            }
            .map(on: mainContext) { objectIDs, context -> [AwfulThread] in
                return objectIDs.compactMap { context.object(with: $0) as? AwfulThread }
        }
    }

    public func listBookmarkedThreads(page: Int) -> Promise<[AwfulThread]> {
        guard
            let backgroundContext = backgroundManagedObjectContext,
            let mainContext = managedObjectContext else
        {
            return Promise(error: PromiseError.missingManagedObjectContext)
        }

        let parameters: KeyValuePairs<String, Any> = [
            "action": "view",
            "perpage": "40",
            "pagenumber": "\(page)"]

        return fetch(method: .get, urlString: "bookmarkthreads.php", parameters: parameters)
            .promise
            .scrape(as: ThreadListScrapeResult.self, on: scrapingQueue)
            .map(on: backgroundContext) { result, context -> [NSManagedObjectID] in
                let threads = try result.upsert(into: context)

                AwfulThread.fetch(in: context) {
                    let threadIDsToIgnore = threads.map { $0.threadID }
                    $0.predicate = .and(
                        .init("\(\AwfulThread.bookmarked) = YES"),
                        .init("\(\AwfulThread.bookmarkListPage) >= \(page)"),
                        .init("NOT(\(\AwfulThread.threadID) IN \(threadIDsToIgnore))")
                    )
                }.forEach { $0.bookmarkListPage = 0 }

                try context.save()

                return threads.map { $0.objectID }
            }
            .map(on: mainContext) { objectIDs, context -> [AwfulThread] in
                return objectIDs.compactMap { context.object(with: $0) as? AwfulThread }
        }
    }

    public func setThread(_ thread: AwfulThread, isBookmarked: Bool) -> Promise<Void> {
        guard let mainContext = managedObjectContext else {
            return Promise(error: PromiseError.missingManagedObjectContext)
        }

        let parameters: KeyValuePairs<String, Any> = [
            "json": "1",
            "action": isBookmarked ? "add" : "remove",
            "threadid": thread.threadID]

        return fetch(method: .post, urlString: "bookmarkthreads.php", parameters: parameters)
            .promise
            .map(on: mainContext) { response, context in
                thread.bookmarked = isBookmarked
                if isBookmarked, thread.bookmarkListPage <= 0 {
                    thread.bookmarkListPage = 1
                }
                try context.save()
        }
    }

    public func rate(_ thread: AwfulThread, as rating: Int) -> Promise<Void> {
        let parameters: KeyValuePairs<String, Any> = [
            "vote": "\(rating.clamped(to: 1...5))",
            "threadid": thread.threadID]

        return fetch(method: .post, urlString: "threadrate.php", parameters: parameters)
            .promise.asVoid()
    }

    public func setBookmarkColor(_ thread: AwfulThread, as category: StarCategory) -> Promise<Void> {
        guard let mainContext = managedObjectContext else {
            return Promise(error: PromiseError.missingManagedObjectContext)
        }

        // we can set the bookmark color by sending a "category_id" parameter with an "add" action
        let parameters: KeyValuePairs<String, Any> = [
            "threadid": thread.threadID,
            "action": "add",
            "category_id": "\(category.rawValue)",
            "json": "1",
        ]

        return fetch(method: .post, urlString: "bookmarkthreads.php", parameters: parameters)
            .promise
            .map(on: mainContext) { response, context in
                if thread.bookmarkListPage <= 0 {
                    thread.bookmarkListPage = 1
                }
                try context.save()
        }
    }
    
    public func markThreadAsSeenUpTo(_ post: Post) -> Promise<Void> {
        guard let threadID = post.thread?.threadID else {
            assertionFailure("post needs a thread ID")
            let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
            return Promise(error: error)
        }

        let parameters: KeyValuePairs<String, Any> = [
            "action": "setseen",
            "threadid": threadID,
            "index": "\(post.threadIndex)"]

        return fetch(method: .post, urlString: "showthread.php", parameters: parameters)
            .promise.asVoid()
    }

    public func markUnread(_ thread: AwfulThread) -> Promise<Void> {
        let parameters: KeyValuePairs<String, Any> = [
            "threadid": thread.threadID,
            "action": "resetseen",
            "json": "1"]

        return fetch(method: .post, urlString: "showthread.php", parameters: parameters)
            .promise.asVoid()
    }

    public func listAvailablePostIcons(inForumIdentifiedBy forumID: String) -> Promise<(primary: [ThreadTag], secondary: [ThreadTag])> {
        guard
            let backgroundContext = backgroundManagedObjectContext,
            let mainContext = managedObjectContext else
        {
            return Promise(error: PromiseError.missingManagedObjectContext)
        }

        let parameters: KeyValuePairs<String, Any> = [
            "action": "newthread",
            "forumid": forumID]

        return fetch(method: .get, urlString: "newthread.php", parameters: parameters)
            .promise
            .scrape(as: PostIconListScrapeResult.self, on: scrapingQueue)
            .map(on: backgroundContext) { parsed, context -> (primary: [NSManagedObjectID], secondary: [NSManagedObjectID]) in
                let managed = try parsed.upsert(into: context)
                try context.save()
                return (primary: managed.primary.map { $0.objectID },
                        secondary: managed.secondary.map { $0.objectID })
            }
            .map(on: mainContext) { objectIDs, context -> (primary: [ThreadTag], secondary: [ThreadTag]) in
                return (
                    primary: objectIDs.primary.compactMap { context.object(with: $0) as? ThreadTag },
                    secondary: objectIDs.secondary.compactMap { context.object(with: $0) as? ThreadTag })
        }
    }

    /// - Parameter postData: A `PostNewThreadFormData` returned by `previewOriginalPostForThread(in:bbcode:)`.
    public func postThread(using formData: PostNewThreadFormData, subject: String, threadTag: ThreadTag?, secondaryTag: ThreadTag?, bbcode: String) -> Promise<AwfulThread> {
        guard
            let backgroundContext = backgroundManagedObjectContext,
            let mainContext = managedObjectContext else
        {
            return Promise(error: PromiseError.missingManagedObjectContext)
        }

        let threadTagObjectID = threadTag?.objectID
        let secondaryTagObjectID = secondaryTag?.objectID

        let params = backgroundContext.perform(.promise) { context -> [Dictionary<String, Any>.Element] in
            _ = try formData.postIcons.upsert(into: context)
            try context.save()

            let form = SubmittableForm(formData.form)

            try form.enter(text: subject, for: "subject")
            try form.enter(text: bbcode, for: "message")

            if
                let objectID = threadTagObjectID,
                let threadTag = context.object(with: objectID) as? ThreadTag,
                let imageName = threadTag.imageName,
                let icon = formData.postIcons.primaryIcons.first(where: { $0.url.map(ThreadTag.imageName) == imageName }),
                !formData.postIcons.selectedPrimaryIconFormName.isEmpty
            {
                try form.select(value: icon.id, for: formData.postIcons.selectedPrimaryIconFormName)
            }

            if
                let objectID = secondaryTagObjectID,
                let threadTag = context.object(with: objectID) as? ThreadTag,
                let imageName = threadTag.imageName,
                let icon = formData.postIcons.secondaryIcons.first(where: { $0.url.map(ThreadTag.imageName) == imageName }),
                !formData.postIcons.selectedSecondaryIconFormName.isEmpty
            {
                try form.select(value: icon.id, for: formData.postIcons.selectedSecondaryIconFormName)
            }

            let submission = form.submit(button: formData.form.submitButton(named: "submit"))
            return prepareFormEntries(submission)
        }

        let threadID = params
            .then { self.fetch(method: .post, urlString: "newthread.php", parameters: $0).promise }
            .map(on: .global(), parseHTML)
            .map(on: .global()) { parsed -> String in
                guard
                    let link = parsed.document.firstNode(matchingSelector: "a[href *= 'showthread']"),
                    let href = link["href"],
                    let components = URLComponents(string: href),
                    let queryItems = components.queryItems,
                    let threadIDPair = queryItems.first(where: { $0.name == "threadid" }),
                    let threadID = threadIDPair.value else
                {
                    throw AwfulCoreError.parseError(description: "The new thread could not be located. Maybe it didn't actually get made. Double-check if your thread has appeared, then try again.")
                }

                return threadID
        }

        return threadID.map(on: mainContext) { threadID, context in
            AwfulThread.objectForKey(objectKey: ThreadKey(threadID: threadID), in: context)
        }
    }

    public struct PostNewThreadFormData {
        fileprivate let form: Form
        fileprivate let postIcons: PostIconListScrapeResult
    }

    /// - Returns: The promise of the previewed post's HTML.
    public func previewOriginalPostForThread(in forum: Forum, bbcode: String) -> CancellablePromise<(previewHTML: String, formData: PostNewThreadFormData)> {
        let (previewForm, cancellable) = fetch(method: .get, urlString: "newthread.php", parameters: [
            "action": "newthread",
            "forumid": forum.forumID])

        let previewParameters = previewForm
            .map(on: .global(), parseHTML)
            .map(on: .global()) { parsed -> [Dictionary<String, Any>.Element] in
                guard let htmlForm = parsed.document.firstNode(matchingSelector: "form[name = 'vbform']") else {
                    if
                        let specialMessage = parsed.document.firstNode(matchingSelector: "#content center div.standard"),
                        specialMessage.textContent.contains("accepting")
                    {
                        throw AwfulCoreError.forbidden(description: "You're not allowed to post threads in this forum")
                    }
                    else {
                        throw AwfulCoreError.parseError(description: "Could not find new thread form")
                    }
                }

                let form = try Form(htmlForm, url: parsed.url)
                let submittable = SubmittableForm(form)

                try submittable.enter(text: bbcode, for: "message")

                let submission = submittable.submit(button: form.submitButton(named: "preview"))
                return prepareFormEntries(submission)
        }

        let htmlAndFormData = previewParameters
            .then { self.fetch(method: .post, urlString: "newthread.php", parameters: $0).promise }
            .map(on: .global(), parseHTML)
            .map(on: .global()) { parsed -> (previewHTML: String, formData: PostNewThreadFormData) in
                guard let postbody = parsed.document.firstNode(matchingSelector: ".postbody") else {
                    throw AwfulCoreError.parseError(description: "Could not find previewed original post")
                }
                workAroundAnnoyingImageBBcodeTagNotMatching(in: postbody)

                let htmlForm = try parsed.document.requiredNode(matchingSelector: "form[name = 'vbform']")
                let form = try Form(htmlForm, url: parsed.url)
                let postIcons = try PostIconListScrapeResult(htmlForm, url: parsed.url)
                let postData = PostNewThreadFormData(form: form, postIcons: postIcons)
                return (previewHTML: postbody.innerHTML, formData: postData)
        }

        return (htmlAndFormData, cancellable)
    }
    
    /**
     Returns info for a random flag image that can sit atop a page of posts in a thread.
     
     Generally only seen in FYAD.
     */
    public func flagForThread(in forum: Forum) -> CancellablePromise<Flag> {
        let (promise, cancellable) = fetch(method: .get, urlString: "flag.php", parameters: ["forumid": forum.forumID])
        
        let result = promise
            .map(on: .global()) { data, response in
                try JSONDecoder().decode(Flag.self, from: data)
        }
        
        return (promise: result, cancellable: cancellable)
    }
    
    public struct Flag: Decodable {
        public let created: String?
        public let path: String
        public let username: String?
    }

    // MARK: Announcements

    /**
     Populates already-scraped announcements with their `bodyHTML`.
     
     - Note: Announcements must first be scraped as part of a thread list for this method to do anything.
     */
    public func listAnnouncements() -> CancellablePromise<[Announcement]> {
        guard
            let backgroundContext = backgroundManagedObjectContext,
            let mainContext = managedObjectContext else
        {
            return (promise: Promise(error: PromiseError.missingManagedObjectContext), cancellable: Operation())
        }

        let (promise, cancellable) = fetch(method: .get, urlString: "announcement.php", parameters: ["forumid": "1"])

        let result = promise
            .scrape(as: AnnouncementListScrapeResult.self, on: scrapingQueue)
            .map(on: backgroundContext) { scrapeResult, context -> [NSManagedObjectID] in
                let announcements = try scrapeResult.upsert(into: context)
                try context.save()
                return announcements.map { $0.objectID }
            }
            .map(on: mainContext) { objectIDs, context -> [Announcement] in
                return objectIDs.compactMap { context.object(with: $0) as? Announcement }
        }

        return (promise: result, cancellable: cancellable)
    }

    // MARK: Posts

    /**
     - Parameter writtenBy: A `User` whose posts should be the only ones listed. If `nil`, posts from all authors are listed.
     - Parameter updateLastReadPost: If `true`, the "last read post" marker on the Forums is updated to include the posts loaded on the page (which is probably what you want). If `false`, the next time the user asks for "next unread post" they'll get the same answer again.
     - Returns: A cancellable promise of:
         - posts: The posts that appeared on the page of the thread.
         - firstUnreadPost: The index of the first unread post on the page (this index starts at 1), or `nil` if no unread post is found.
         - advertisementHTML: Raw HTML of an SA-hosted banner ad.
     */
    public func listPosts(
        in thread: AwfulThread,
        writtenBy author: User?,
        page: ThreadPage,
        updateLastReadPost: Bool
    ) -> CancellablePromise<(posts: [Post], firstUnreadPost: Int?, advertisementHTML: String)> {
        guard
            let backgroundContext = backgroundManagedObjectContext,
            let mainContext = managedObjectContext else
        {
            return (Promise(error: PromiseError.missingManagedObjectContext), Operation())
        }

        var parameters: Dictionary<String, Any> = [
            "threadid": thread.threadID,
            "perpage": "40"]

        switch page {
        case .nextUnread:
            parameters["goto"] = "newpost"
        case .last:
            parameters["goto"] = "lastpost"
        case .specific(let pageNumber):
            parameters["pagenumber"] = "\(pageNumber)"
        }

        if !updateLastReadPost {
            parameters["noseen"] = "1"
        }

        if let userID = author?.userID {
            parameters["userid"] = userID
        }

        // SA: We set perpage=40 above to effectively ignore the user's "number of posts per page" setting on the Forums proper. When we get redirected (i.e. goto=newpost or goto=lastpost), the page we're redirected to is appropriate for our hardcoded perpage=40. However, the redirected URL has **no** perpage parameter, so it defaults to the user's setting from the Forums proper. This block maintains our hardcoded perpage value.
        func redirectBlock(
            task: URLSessionTask,
            response: HTTPURLResponse,
            newRequest: URLRequest
        ) -> URLRequest? {
            var components = newRequest.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: true) }
            let queryItems = (components?.queryItems ?? [])
                .filter { $0.name != "perpage" }
            components?.queryItems = queryItems
                + [URLQueryItem(name: "perpage", value: "40")]

            var request = newRequest
            request.url = components?.url
            return request
        }

        let (promise, cancellable) = fetch(method: .get, urlString: "showthread.php", parameters: parameters, redirectBlock: redirectBlock)

        let parsed = promise
            .scrape(as: PostsPageScrapeResult.self, on: scrapingQueue)

        let posts = parsed
            .map(on: backgroundContext) { scrapeResult, context -> [NSManagedObjectID] in
                let posts = try scrapeResult.upsert(into: context)
                try context.save()
                return posts.map { $0.objectID }
            }
            .map(on: mainContext) { objectIDs, context -> [Post] in
                return objectIDs.compactMap { context.object(with: $0) as? Post }
            }

        let altogether = when(fulfilled: posts, parsed)
            .map { posts, scrapeResult in
                return (posts: posts,
                        // post index is 1-based
                        firstUnreadPost: scrapeResult.jumpToPostIndex.map { $0 + 1 },
                        advertisementHTML: scrapeResult.advertisement)
        }

        return (altogether, cancellable)
    }

    /**
     - Parameter post: An ignored post whose author and innerHTML should be filled.
     */
    public func readIgnoredPost(_ post: Post) -> Promise<Void> {
        guard
            let backgroundContext = backgroundManagedObjectContext,
            let postContext = post.managedObjectContext else
        {
            return Promise(error: PromiseError.missingManagedObjectContext)
        }

        let parameters: KeyValuePairs<String, Any> = [
            "action": "showpost",
            "postid": post.postID]

        return fetch(method: .get, urlString: "showthread.php", parameters: parameters)
            .promise
            .scrape(as: ShowPostScrapeResult.self, on: scrapingQueue)
            .map(on: backgroundContext) { scrapeResult, context -> Void in
                _ = try scrapeResult.upsert(into: context)
                try context.save()
            }
            .map(on: postContext) { (_, context) -> Void in
                context.refresh(post, mergeChanges: true)
        }
    }

    public enum ReplyLocation {
        case lastPostInThread
        case post(Post)
    }

    public func reply(to thread: AwfulThread, bbcode: String) -> Promise<ReplyLocation> {
        guard let mainContext = managedObjectContext else {
            return Promise(error: PromiseError.missingManagedObjectContext)
        }

        let wasThreadClosed = thread.closed

        let startParams: KeyValuePairs<String, Any> = [
            "action": "newreply",
            "threadid": thread.threadID]
        let params = fetch(method: .get, urlString: "newreply.php", parameters: startParams)
            .promise
            .map(on: .global(), parseHTML)
            .map(on: .global()) { parsed -> [Dictionary<String, Any>.Element] in
                guard let htmlForm = parsed.document.firstNode(matchingSelector: "form[name='vbform']") else {
                    let description = wasThreadClosed
                        ? "Could not reply; the thread may be closed."
                        : "Could not reply; failed to find the form."
                    throw AwfulCoreError.parseError(description: description)
                }

                let parsedForm = try Form(htmlForm, url: parsed.url)
                let form = SubmittableForm(parsedForm)
                try form.enter(text: bbcode, for: "message")
                let submission = form.submit(button: parsedForm.submitButton(named: "submit"))
                return prepareFormEntries(submission)
        }

        let postID = params
            .then { self.fetch(method: .post, urlString: "newreply.php", parameters: $0).promise }
            .map(on: .global(), parseHTML)
            .map(on: .global()) { parsed -> String? in
                let link = parsed.document.firstNode(matchingSelector: "a[href *= 'goto=post']")
                    ?? parsed.document.firstNode(matchingSelector: "a[href *= 'goto=lastpost']")
                let queryItems = link
                    .flatMap { $0["href"] }
                    .flatMap { URLComponents(string: $0) }
                    .flatMap { $0.queryItems }
                if
                    let goto = queryItems?.first(where: { $0.name == "goto" }),
                    goto.value == "post",
                    let postID = queryItems?.first(where: { $0.name == "postid" })?.value
                {
                    return postID
                }
                else {
                    return nil
                }
        }

        return postID
            .map(on: mainContext) { postID, context -> ReplyLocation in
                if let postID = postID {
                    return .post(Post.objectForKey(objectKey: PostKey(postID: postID), in: context))
                }
                else {
                    return .lastPostInThread
                }
        }
    }

    public func previewReply(to thread: AwfulThread, bbcode: String) -> CancellablePromise<String> {
        let (promise, cancellable) = fetch(method: .get, urlString: "newreply.php", parameters: [
            "action": "newreply",
            "threadid": thread.threadID])

        let params = promise
            .map(on: .global(), parseHTML)
            .map(on: .global()) { parsed -> [Dictionary<String, Any>.Element] in
                let htmlForm = try parsed.document.requiredNode(matchingSelector: "form[name = 'vbform']")
                let scrapedForm = try Form(htmlForm, url: parsed.url)
                let form = SubmittableForm(scrapedForm)
                try form.enter(text: bbcode, for: "message")
                let submission = form.submit(button: scrapedForm.submitButton(named: "preview"))
                return prepareFormEntries(submission)
        }

        let parsed = params
            .then { self.fetch(method: .post, urlString: "newreply.php", parameters: $0).promise }
            .map(on: .global(), parseHTML)
            .map(on: .global()) { parsed -> String in
                guard let postbody = parsed.document.firstNode(matchingSelector: ".postbody") else {
                    throw AwfulCoreError.parseError(description: "Could not find previewed post")
                }

                workAroundAnnoyingImageBBcodeTagNotMatching(in: postbody)
                return postbody.innerHTML
        }

        return (promise: parsed, cancellable: cancellable)
    }

    public func findBBcodeContents(of post: Post) -> Promise<String> {
        let parameters: KeyValuePairs<String, Any> = [
            "action": "editpost",
            "postid": post.postID]

        return fetch(method: .get, urlString: "editpost.php", parameters: parameters)
            .promise
            .map(on: .global(), parseHTML)
            .map(on: .global(), findMessageText)
    }

    public func quoteBBcodeContents(of post: Post) -> Promise<String> {
        let parameters: KeyValuePairs<String, Any> = [
            "action": "newreply",
            "postid": post.postID]

        return fetch(method: .get, urlString: "newreply.php", parameters: parameters)
            .promise
            .map(on: .global(), parseHTML)
            .map(on: .global(), findMessageText)
    }

    public func edit(_ post: Post, bbcode: String) -> Promise<Void> {
        return editForm(for: post)
            .promise
            .map(on: .global()) { parsedForm -> [Dictionary<String, Any>.Element] in
                let form = SubmittableForm(parsedForm)
                try form.enter(text: bbcode, for: "message")
                let submission = form.submit(button: parsedForm.submitButton(named: "submit"))
                return prepareFormEntries(submission)
            }
            .then { self.fetch(method: .post, urlString: "editpost.php", parameters: $0).promise }
            .asVoid()
    }

    private func editForm(for post: Post) -> CancellablePromise<Form> {
        let startParams: KeyValuePairs<String, Any> = [
            "action": "editpost",
            "postid": post.postID]

        let (promise: promise, cancellable: cancellable) = fetch(method: .get, urlString: "editpost.php", parameters: startParams)

        let parsed = promise
            .map(on: .global(), parseHTML)
            .map(on: .global()) { parsed -> Form in
                guard let htmlForm = parsed.document.firstNode(matchingSelector: "form[name='vbform']") else {
                    if
                        let specialMessage = parsed.document.firstNode(matchingSelector: "#content center div.standard"),
                        specialMessage.textContent.contains("permission")
                    {
                        throw AwfulCoreError.forbidden(description: "You're not allowed to edit posts in this thread")
                    }
                    else {
                        throw AwfulCoreError.parseError(description: "Failed to edit post; could not find form")
                    }
                }

                return try Form(htmlForm, url: parsed.url)
        }

        return (promise: parsed, cancellable: cancellable)
    }

    /**
     - Parameter postID: The post's ID. Specified directly in case no such post exists, which would make for a useless `Post`.
     - Returns: The promise of a post (with its `thread` set) and the page containing the post (may be `AwfulThreadPage.last`).
     */
    public func locatePost(
        id postID: String,
        updateLastReadPost: Bool
    ) -> Promise<(post: Post, page: ThreadPage)> {
        guard let mainContext = managedObjectContext else {
            return Promise(error: PromiseError.missingManagedObjectContext)
        }

        // The SA Forums will direct a certain URL to the thread with a given post. We'll wait for that redirect, then parse out the info we need.
        let redirectURL = Promise<URL>.pending()

        func redirectBlock(task: URLSessionTask, response: HTTPURLResponse, newRequest: URLRequest) -> URLRequest? {
            if
                let url = newRequest.url,
                url.lastPathComponent == "showthread.php",
                let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
                let queryItems = components.queryItems,
                queryItems.first(where: { $0.name == "goto" }) != nil
            {
                return newRequest
            }

            task.cancel()

            guard let url = newRequest.url else {
                redirectURL.resolver.reject(AwfulCoreError.parseError(description: "The post could not be found (missing URL)"))
                return nil
            }

            redirectURL.resolver.fulfill(url)
            return nil
        }

        let parameters: KeyValuePairs<String, Any> = [
            "goto": "post",
            "postid": postID,
            "noseen": updateLastReadPost ? "0" : "1"]

        fetch(method: .get, urlString: "showthread.php", parameters: parameters, redirectBlock: redirectBlock)
            .promise
            .done { dataAndResponse in
                // Once we have the redirect we want, we cancel the operation. So if this "success" callback gets called, we've actually failed.
                redirectURL.resolver.reject(AwfulCoreError.parseError(description: "The post could not be found"))
            }
            .catch { error in
                // This catch excludes cancellation, so we've legitimately failed.
                redirectURL.resolver.reject(error)
        }

        return redirectURL.promise
            .map(on: .global()) { url -> (threadID: String, page: ThreadPage) in
                guard
                    let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
                    let threadID = components.queryItems?.first(where: { $0.name == "threadid" })?.value,
                    !threadID.isEmpty,
                    let rawPagenumber = components.queryItems?.first(where: { $0.name == "pagenumber" })?.value,
                    let pageNumber = Int(rawPagenumber) else
                {
                    throw AwfulCoreError.parseError(description: "The thread ID or page number could not be found")
                }

                return (threadID: threadID, page: .specific(pageNumber))
            }
            .map(on: mainContext) { parsed, context -> (post: Post, page: ThreadPage) in
                let (threadID: threadID, page: page) = parsed
                let post = Post.objectForKey(objectKey: PostKey(postID: postID), in: mainContext)
                let thread = AwfulThread.objectForKey(objectKey: ThreadKey(threadID: threadID), in: mainContext)

                post.thread = thread
                try context.save()

                return (post: post, page: page)
        }
    }

    public func previewEdit(to post: Post, bbcode: String) -> CancellablePromise<String> {
        let (promise, cancellable) = editForm(for: post)

        let params = promise
            .map(on: .global()) { parsedForm -> [Dictionary<String, Any>.Element] in
                let form = SubmittableForm(parsedForm)
                try form.enter(text: bbcode, for: "message")
                let submission = form.submit(button: parsedForm.submitButton(named: "preview"))
                return prepareFormEntries(submission)
        }

        let parsed = params
            .then { self.fetch(method: .post, urlString: "editpost.php", parameters: $0).promise }
            .map(on: .global(), parseHTML)
            .map(on: .global()) { parsed -> String in
                guard let postbody = parsed.document.firstNode(matchingSelector: ".postbody") else {
                    throw AwfulCoreError.parseError(description: "Could not find previewed post")
                }

                workAroundAnnoyingImageBBcodeTagNotMatching(in: postbody)
                return postbody.innerHTML
        }

        return (promise: parsed, cancellable: cancellable)
    }

    /**
     - Parameter reason: A further explanation of what's wrong with the post.
     */
    public func report(_ post: Post, nws: Bool, reason: String) -> Promise<Void> {
        var parameters: Dictionary<String, Any> = [
            "action": "submit",
            "postid": post.postID,
            "comments": String(reason.prefix(960))]
        
        if (nws) {
            parameters["nws"] = "yes"
        }

        return fetch(method: .post, urlString: "modalert.php", parameters: parameters)
            .promise.asVoid()
            .recover { error in
                print("error reporting post \(post.postID): \(error)")
        }
    }

    // MARK: Users

    private func profile(parameters: [String: Any]) -> Promise<NSManagedObjectID> {
        guard let backgroundContext = backgroundManagedObjectContext else {
            return Promise(error: PromiseError.missingManagedObjectContext)
        }

        return fetch(method: .get, urlString: "member.php", parameters: parameters)
            .promise
            .scrape(as: ProfileScrapeResult.self, on: scrapingQueue)
            .map(on: backgroundContext) { scrapeResult, context -> NSManagedObjectID in
                let profile = try scrapeResult.upsert(into: context)
                try context.save()
                return profile.objectID
            }
    }

    public func profileLoggedInUser() -> Promise<User> {
        guard let mainContext = managedObjectContext else {
            return Promise(error: PromiseError.missingManagedObjectContext)
        }

        return profile(parameters: ["action": "getinfo"])
            .map(on: mainContext) { objectID, context -> User in
                guard let profile = context.object(with: objectID) as? Profile else {
                    throw AwfulCoreError.parseError(description: "Could not save profile")
                }

                return profile.user
        }
    }

    /**
     - Parameter id: The user's ID. Specified directly in case no such user exists, which would make for a useless `User`.
     - Parameter username: The user's username. If userID is not given, username must be given.
     */
    public func profileUser(id userID: String?, username: String?) -> Promise<Profile> {
        assert(userID != nil || username != nil)

        guard let mainContext = managedObjectContext else {
            return Promise(error: PromiseError.missingManagedObjectContext)
        }

        var parameters = ["action": "getinfo"]
        if let userID = userID, !userID.isEmpty {
            parameters["userid"] = userID
        }
        else if let username = username {
            parameters["username"] = username
        }

        return profile(parameters: parameters)
            .map(on: mainContext) { objectID, context -> Profile in
                guard let profile = context.object(with: objectID) as? Profile else {
                    throw AwfulCoreError.parseError(description: "Could not save profile")
                }

                return profile
        }
    }

    private func lepersColony(parameters: [String: Any]) -> Promise<[LepersColonyScrapeResult.Punishment]> {
        return fetch(method: .get, urlString: "banlist.php", parameters: parameters)
            .promise
            .map(on: .global()) { data, response -> [LepersColonyScrapeResult.Punishment] in
                let (document: document, url: url) = try parseHTML(data: data, response: response)
                let result = try LepersColonyScrapeResult(document, url: url)
                return result.punishments
        }
    }

    public func listPunishments(of user: User?, page: Int) -> Promise<[LepersColonyScrapeResult.Punishment]> {
        guard let user = user else {
            return lepersColony(parameters: ["pagenumber": "\(page)"])
        }

        let userID: Promise<String>
        if !user.userID.isEmpty {
            userID = .value(user.userID)
        }
        else {
            guard let username = user.username else {
                assertionFailure("need user ID or username")
                return lepersColony(parameters: ["pagenumber": "\(page)"])
            }

            userID = profileUser(id: nil, username: username)
                .map { $0.user.userID }
        }

        return userID
            .then { userID -> Promise<[LepersColonyScrapeResult.Punishment]> in
                let parameters = [
                    "pagenumber": "\(page)",
                    "userid": userID]
                return self.lepersColony(parameters: parameters)
        }
    }

    // MARK: Private Messages

    public func listPrivateMessagesInInbox() -> Promise<[PrivateMessage]> {
        guard
            let mainContext = managedObjectContext,
            let backgroundContext = backgroundManagedObjectContext else
        {
            return Promise(error: PromiseError.missingManagedObjectContext)
        }

        return fetch(method: .get, urlString: "private.php", parameters: [])
            .promise
            .scrape(as: PrivateMessageFolderScrapeResult.self, on: scrapingQueue)
            .map(on: backgroundContext) { result, context -> [NSManagedObjectID] in
                let messages = try result.upsert(into: context)
                try context.save()

                return messages.map { $0.objectID }
            }
            .map(on: mainContext) { (objectIDs, context) -> [PrivateMessage] in
                return objectIDs.compactMap { context.object(with: $0) as? PrivateMessage }
        }
    }

    public func deletePrivateMessage(_ message: PrivateMessage) -> Promise<Void> {
        let parameters: KeyValuePairs<String, Any> = [
            "action": "dodelete",
            "privatemessageid": message.messageID,
            "delete": "yes"]

        return fetch(method: .post, urlString: "private.php", parameters: parameters)
            .promise
            .map(on: .global(), parseHTML)
            .map(on: .global()) { document, url -> Void in
                try checkServerErrors(document)
            }
    }

    public func readPrivateMessage(identifiedBy messageKey: PrivateMessageKey) -> Promise<PrivateMessage> {
        guard
            let mainContext = managedObjectContext,
            let backgroundContext = backgroundManagedObjectContext else
        {
            return Promise(error: PromiseError.missingManagedObjectContext)
        }

        let parameters: KeyValuePairs<String, Any> = [
            "action": "show",
            "privatemessageid": messageKey.messageID]

        return fetch(method: .get, urlString: "private.php", parameters: parameters)
            .promise
            .scrape(as: PrivateMessageScrapeResult.self, on: scrapingQueue)
            .map(on: backgroundContext) { scrapeResult, context -> NSManagedObjectID in
                let message = try scrapeResult.upsert(into: context)
                try context.save()
                return message.objectID
            }
            .map(on: mainContext) { objectID, context -> PrivateMessage in
                guard let privateMessage = context.object(with: objectID) as? PrivateMessage else {
                    throw AwfulCoreError.parseError(description: "Could not save message")
                }
                return privateMessage
        }
    }

    public func quoteBBcodeContents(of message: PrivateMessage) -> Promise<String> {
        let parameters: KeyValuePairs<String, Any> = [
            "action": "newmessage",
            "privatemessageid": message.messageID]

        return fetch(method: .get, urlString: "private.php", parameters: parameters)
            .promise
            .map(on: .global(), parseHTML)
            .map(on: .global(), findMessageText)
    }

    public func listAvailablePrivateMessageThreadTags() -> Promise<[ThreadTag]> {
        guard
            let mainContext = managedObjectContext,
            let backgroundContext = backgroundManagedObjectContext else
        {
            return Promise(error: PromiseError.missingManagedObjectContext)
        }

        let parameters: KeyValuePairs<String, Any> = ["action": "newmessage"]

        return fetch(method: .get, urlString: "private.php", parameters: parameters)
            .promise
            .scrape(as: PostIconListScrapeResult.self, on: scrapingQueue)
            .map(on: backgroundContext) { parsed, context -> [NSManagedObjectID] in
                let managed = try parsed.upsert(into: context)
                try context.save()
                return managed.primary.map { $0.objectID }
            }
            .map(on: mainContext) { managedObjectIDs, context -> [ThreadTag] in
                return managedObjectIDs.compactMap { context.object(with: $0) as? ThreadTag }
        }
    }

    /**
     - Parameters:
        - to: The intended recipient's username. (Requiring a `User` would be unhelpful as the username is typed in and may not actually exist.)
        - regarding: Should be `nil` if `forwarding` parameter is non-`nil`.
        - forwarding: Should be `nil` if `regarding` is non-`nil`.
     */
    public func sendPrivateMessage(to username: String, subject: String, threadTag: ThreadTag?, bbcode: String, regarding regardingMessage: PrivateMessage?, forwarding forwardedMessage: PrivateMessage?) -> Promise<Void> {
        var parameters: Dictionary<String, Any> = [
            "touser": username,
            "title": subject,
            "iconid": threadTag?.threadTagID ?? "0",
            "message": bbcode,
            "action": "dosend",
            "forward": forwardedMessage?.messageID == nil ? "" : "true",
            "savecopy": "yes",
            "submit": "Send Message"]

        if let prevmessageID = (regardingMessage ?? forwardedMessage)?.messageID {
            parameters["prevmessageid"] = prevmessageID
        }

        return fetch(method: .post, urlString: "private.php", parameters: parameters)
            .promise.asVoid()
    }
    
    // MARK: Ignore List
    
    /// - Returns: The promise of a form submittable to `updateIgnoredUsers()`.
    public func listIgnoredUsers() -> Promise<IgnoreListForm> {
        let parameters: KeyValuePairs<String, Any> = [
            "action": "viewlist",
            "userlist": "ignore"]
        
        return fetch(method: .get, urlString: "member2.php", parameters: parameters)
            .promise
            .map(on: .global(), parseHTML)
            .map(on: .global()) { (parsed: ParsedDocument) -> IgnoreListForm in
                let el = try parsed.document.requiredNode(matchingSelector: "form[action = 'member2.php']")
                let form = try Form(el, url: parsed.url)
                return try IgnoreListForm(form)
        }
    }
    
    /**
     - Parameter form: An `IgnoreListForm` that originated from a call to `listIgnoredUsers()`.
     - Note: The promise can fail with an `IgnoreListChangeError`, which may be useful to consider separately from the usual network-related errors and `ScrapingError`.
     */
    public func updateIgnoredUsers(_ form: IgnoreListForm) -> Promise<Void> {
        let submittable: SubmittableForm
        do {
            submittable = try form.makeSubmittableForm()
        }
        catch {
            return Promise(error: error)
        }
        
        let parameters = prepareFormEntries(submittable.submit(button: form.submitButton))
        return fetch(method: .post, urlString: "member2.php", parameters: parameters)
            .promise
            .scrape(as: IgnoreListChangeScrapeResult.self, on: scrapingQueue)
            .done(on: .global()) {
                if case .failure(let error) = $0 {
                    throw error
                }
        }
    }
    
    /// Attempts to parse the `formkey` string value from a user's profile page (`member.php`)
    /// This page has two formkey elements, one for the buddy list and one for the ignorelist, so we parse using `findIgnoreFormkey`
    /**
     - Parameters:
     - userid: The user we're ignoring's userid
     - action:: Will be `getinfo` while using the profile page (`member.php`) method
     */
    private func getProfilePageIgnoreFormkey(userid: String) -> Promise<String> {
        let parameters: Dictionary<String, Any> = [
            "userid": userid,
            "action": "getinfo"
        ]
        
        return fetch(method: .get, urlString: "member.php", parameters: parameters)
            .promise
            .map(on: .global(), parseHTML)
            .map(on: .global(), findIgnoreFormkey)
    }
    
    /// Attempts to add a user to the ignore list using the profile page ignore form.
    /// This allows addition of new ignore list entries without the error caused by a potential preexisting ignore list containing a moderator, so long as this new entry attempt is not themselves a moderator
    /// (in which case an error is correct)
    /**
     - Parameters:
     - userid: The ignored user's userid
     - action: `addlist` is the action used by the SA profile page (`member.php`) ignore button
     - formkey: Scraped key from profile page (`member.php`) and required for the subsequent member2.php action
     - userlist: Always `ignore` for the ignore list
     */
    public func addUserToIgnoreList(userid: String) -> Promise<Void> {
        return firstly {
            getProfilePageIgnoreFormkey(userid: userid)
        }.then {
            let parameters: Dictionary<String, Any> = [
                "userid": userid,
                "action": "addlist",
                "formkey": $0,
                "userlist": "ignore"
            ]
            
            return self.fetch(method: .post, urlString: "member2.php", parameters: parameters)
                .promise
                .scrape(as: IgnoreListChangeScrapeResult.self, on: self.scrapingQueue)
                .done(on: .global()) {
                    if case .failure(let error) = $0 {
                        throw error
                    }
                }
        }
    }
    
    /// Attempts to remove a user from the ignore list. This can fail for many reasons, including having a moderator or admin on your ignore list.
    public func removeUserFromIgnoreList(username: String) -> Promise<Void> {
        return listIgnoredUsers()
            .then { form -> Promise<Void> in
                var form = form
                guard let i = form.usernames.firstIndex(of: username) else { return Promise.value(()) }
                
                form.usernames.remove(at: i)
                return self.updateIgnoredUsers(form)
            }
    }
}


/// A (typically network) operation that can be cancelled.
public protocol Cancellable: AnyObject {

    /// Idempotent.
    func cancel()
}

extension Operation: Cancellable {}
extension URLSessionTask: Cancellable {}


private typealias ParsedDocument = (document: HTMLDocument, url: URL?)

private func parseHTML(data: Data, response: URLResponse) throws -> ParsedDocument {
    let contentType: String? = {
        guard let response = response as? HTTPURLResponse else { return nil }
        return response.allHeaderFields["Content-Type"] as? String
    }()
    let document = HTMLDocument(data: data, contentTypeHeader: contentType)
    try checkServerErrors(document)
    return (document: document, url: response.url)
}

private func parseJSONDict(data: Data, response: URLResponse) throws -> [String: Any] {
    let json = try JSONSerialization.jsonObject(with: data, options: [])
    guard let dict = json as? [String: Any] else {
        throw ForumsClient.PromiseError.unexpectedContentType("\(type(of: json))", expected: "Dictionary<String, Any>")
    }
    return dict
}


private func workAroundAnnoyingImageBBcodeTagNotMatching(in postbody: HTMLElement) {
    for img in postbody.nodes(matchingSelector: "img[src^='http://awful-image']") {
        if let src = img["src"] {
            let suffix = src.dropFirst("http://".count)
            img["src"] = String(suffix)
        }
    }
}


extension NSManagedObjectContext {
    fileprivate func perform<T>(_: PMKNamespacer, execute body: @escaping (_ context: NSManagedObjectContext) throws -> T) -> Promise<T> {
        let (promise, resolver) = Promise<T>.pending()
        perform {
            do {
                resolver.fulfill(try body(self))
            } catch {
                resolver.reject(error)
            }
        }
        return promise
    }
}

private extension Promise {
    func map<U>(on context: NSManagedObjectContext, _ transform: @escaping (T, _ context: NSManagedObjectContext) throws -> U) -> Promise<U> {
        return then { value -> Promise<U> in
            let (promise, resolver) = Promise<U>.pending()
            context.perform {
                do {
                    resolver.fulfill(try transform(value, context))
                }
                catch {
                    resolver.reject(error)
                }
            }
            return promise
        }
    }
}

private extension Promise where T == (data: Data, response: URLResponse) {
    func scrape<U: ScrapeResult>(
        as _: U.Type,
        on queue: DispatchQueue
    ) -> Promise<U> {
        map(on: queue) {
            let parsed = try parseHTML(data: $0.data, response: $0.response)
            return try U.init(parsed.document, url: parsed.url)
        }
    }

    func decode<U: Decodable>(
        as _: U.Type,
        on queue: DispatchQueue
    ) -> Promise<U> {
        map(on: queue) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .awful
            return try decoder.decode(U.self, from: $0.data)
        }
    }
}


enum ServerError: LocalizedError {
    case databaseUnavailable(title: String, message: String)
    case standard(title: String, message: String)

    var errorDescription: String? {
        switch self {
        case .databaseUnavailable(title: _, message: let message),
             .standard(title: _, message: let message):
            return message
        }
    }
}

private func checkServerErrors(_ document: HTMLDocument) throws {
    if let result = try? DatabaseUnavailableScrapeResult(document, url: nil) {
        throw ServerError.databaseUnavailable(title: result.title, message: result.message)
    }
    else if let result = try? StandardErrorScrapeResult(document, url: nil) {
        throw ServerError.standard(title: result.title, message: result.message)
    }
}


private func prepareFormEntries(_ submission: SubmittableForm.PreparedSubmission) -> [Dictionary<String, Any>.Element] {
    return submission.entries.map { ($0.name, $0.value ) }
}


private func findMessageText(in parsed: ParsedDocument) throws -> String {
    let form = try Form(parsed.document.requiredNode(matchingSelector: "form[name='vbform']"), url: parsed.url)
    guard let message = form.controls.first(where: { $0.name == "message" }) else {
        throw ScrapingError.missingExpectedElement("textarea[name = 'message']")
    }
    return (message.value as NSString).html_stringByUnescapingHTML
}

private func findIgnoreFormkey(in parsed: ParsedDocument) throws -> String {
    return parsed.document.firstNode(matchingSelector: "input[value='ignore']")
        .flatMap { $0.parent?.firstNode(matchingSelector: "input[name = 'formkey']") }
        .map { $0["value"] }
    ?? ""
}
