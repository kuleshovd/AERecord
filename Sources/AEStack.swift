//
// AEStack.swift
//
// Copyright (c) 2014-2016 Marko Tadić <tadija@me.com> http://tadija.net
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//

import CoreData

/// This internal class is core of AERecord as it configures and accesses Core Data Stack.
class AEStack {
    
    // MARK: - Singleton
    
    static let shared = AEStack()
    
    // MARK: - Defaults
    
    class var defaultModel: NSManagedObjectModel {
        return NSManagedObjectModel.mergedModel(from: nil)!
    }
    
    class var defaultName: String {
        guard let identifier = Bundle.main.bundleIdentifier
        else { return Bundle(for: AEStack.self).bundleIdentifier! }
        return identifier
    }
    
    class var defaultURL: URL {
        return storeURL(forName: defaultName)
    }
    
    class var defaultDirectory: FileManager.SearchPathDirectory {
        #if os(tvOS)
            return .CachesDirectory
        #else
            return .documentDirectory
        #endif
    }
    
    var defaultContext: NSManagedObjectContext {
        if Thread.isMainThread {
            return mainContext
        } else {
            return backgroundContext
        }
    }
    
    // MARK: - Properties
    
    var model: NSManagedObjectModel?
    var coordinator: NSPersistentStoreCoordinator?
    
    var mainContext: NSManagedObjectContext!
    var backgroundContext: NSManagedObjectContext!
    
    // MARK: - Stack
    
    class func storeURL(forName name: String) -> URL {
        let fileManager = FileManager.default
        let directoryURL = fileManager.urls(for: defaultDirectory, in: .userDomainMask).last!
        let storeName = "\(name).sqlite"
        return directoryURL.appendingPathComponent(storeName)
    }
    
    class func modelFromBundle(for aClass: AnyClass) -> NSManagedObjectModel {
        let bundle = Bundle(for: aClass)
        return NSManagedObjectModel.mergedModel(from: [bundle])!
    }
    
    func loadCoreDataStack(
        managedObjectModel: NSManagedObjectModel = defaultModel,
        storeType: String = NSSQLiteStoreType,
        configuration: String? = nil,
        storeURL: URL = defaultURL,
        options: [AnyHashable : Any]? = nil) throws {
        
        model = managedObjectModel
        configureManagedObjectContexts()
        try configureStoreCoordinator(model: managedObjectModel, type: storeType,
                                      configuration: configuration, url: storeURL, options: options)
        startReceivingContextNotifications()
    }
    
    private func configureManagedObjectContexts() {
        mainContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        backgroundContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
    }
    
    private func configureStoreCoordinator(model: NSManagedObjectModel, type: String,
                                           configuration: String?, url: URL, options: [AnyHashable : Any]?) throws {
        
        coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        try coordinator?.addPersistentStore(ofType: type, configurationName: configuration, at: url, options: options)
        mainContext.persistentStoreCoordinator = coordinator
        backgroundContext.persistentStoreCoordinator = coordinator
    }
    
    func destroyCoreDataStack(storeURL: URL = defaultURL) throws {
        /// - NOTE: must load this core data stack first
        /// because there is no `storeCoordinator` if `destroyCoreDataStack` is called before `loadCoreDataStack`
        /// also if we're in other stack currently that `storeCoordinator` doesn't know about this `storeURL`
        try loadCoreDataStack(storeURL: storeURL)
        
        stopReceivingContextNotifications()
        resetManagedObjectContexts()
        try removePersistentStore(storeURL: storeURL)
        resetCoordinatorAndModel()
    }
    
    private func resetManagedObjectContexts() {
        mainContext.reset()
        backgroundContext.reset()
    }
    
    private func removePersistentStore(storeURL: URL) throws {
        if let store = coordinator?.persistentStore(for: storeURL) {
            try coordinator?.remove(store)
            try FileManager.default.removeItem(at: storeURL)
        }
    }
    
    private func resetCoordinatorAndModel() {
        coordinator = nil
        model = nil
    }
    
    deinit {
        stopReceivingContextNotifications()
    }
    
    // MARK: - Context
    
    func execute<T: NSManagedObject>(fetchRequest request: NSFetchRequest<T>,
                 inContext context: NSManagedObjectContext) -> [T] {
        
        var fetchedObjects = [T]()
        context.performAndWait {
            do {
                fetchedObjects = try context.fetch(request)
            } catch {
                debugPrint(error)
            }
        }
        return fetchedObjects
    }
    
    func save(context: NSManagedObjectContext) {
        context.perform {
            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    debugPrint(error)
                }
            }
        }
    }
    
    func saveAndWait(context: NSManagedObjectContext) {
        context.performAndWait {
            if context.hasChanges {
                do {
                    try context.save()
                } catch {
                    debugPrint(error)
                }
            }
        }
    }
    
    class func refreshObjects(inContext context: NSManagedObjectContext = AERecord.Context.default,
                              objectIDs: [NSManagedObjectID], mergeChanges: Bool) {
        
        for objectID in objectIDs {
            context.performAndWait {
                do {
                    let managedObject = try context.existingObject(with: objectID)
                    // turn managed object into fault
                    context.refresh(managedObject, mergeChanges: mergeChanges)
                } catch {
                    print(error)
                }
            }
        }
    }
    
    class func refreshRegisteredObjects(inContext context: NSManagedObjectContext, mergeChanges: Bool) {
        let registeredObjectIDs = context.registeredObjects.map { return $0.objectID }
        refreshObjects(objectIDs: registeredObjectIDs, mergeChanges: mergeChanges)
    }
    
    func truncateAllData(inContext context: NSManagedObjectContext) {
        if let mom = model {
            for entity in mom.entities {
                if let entityType = NSClassFromString(entity.managedObjectClassName) as? NSManagedObject.Type {
                    entityType.deleteAll(context: context)
                }
            }
        }
    }
    
    @objc func contextDidSave(_ notification: Notification) {
        guard
            let context = notification.object as? NSManagedObjectContext,
            let contextToRefresh = context == mainContext ? backgroundContext : mainContext
        else { return }
        
        mergeChanges(inContext: contextToRefresh, fromNotification: notification)
    }
    
    private func mergeChanges(inContext context: NSManagedObjectContext, fromNotification notification: Notification) {
        context.perform {
            context.mergeChanges(fromContextDidSave: notification)
        }
    }
    
    // MARK: - Notifications
    
    func startReceivingContextNotifications() {
        let center = NotificationCenter.default
        
        // Contexts Sync
        let contextDidSave = #selector(AEStack.contextDidSave(_:))
        center.addObserver(self, selector: contextDidSave, name: .NSManagedObjectContextDidSave, object: mainContext)
        center.addObserver(self, selector: contextDidSave, name: .NSManagedObjectContextDidSave, object: backgroundContext)
        
        // iCloud Support
        center.addObserver(self, selector: #selector(AEStack.storesWillChange(_:)), name: .NSPersistentStoreCoordinatorStoresWillChange, object: coordinator)
        center.addObserver(self, selector: #selector(AEStack.storesDidChange(_:)), name: .NSPersistentStoreCoordinatorStoresDidChange, object: coordinator)
        center.addObserver(self, selector: #selector(AEStack.willRemoveStore(_:)), name: .NSPersistentStoreCoordinatorWillRemoveStore, object: coordinator)
        
        #if !(os(tvOS) || os(watchOS))
            let didImport = #selector(AEStack.persistentStoreDidImportUbiquitousContentChanges(_:))
            center.addObserver(self, selector: didImport, name: .NSPersistentStoreDidImportUbiquitousContentChanges, object: coordinator)
        #endif
    }
    
    func stopReceivingContextNotifications() {
        let center = NotificationCenter.default
        center.removeObserver(self)
    }
    
    // MARK: - iCloud Support
    
    @objc func storesWillChange(_ notification: Notification) {
        saveAndWait(context: defaultContext)
    }
    
    @objc func storesDidChange(_ notification: Notification) {
        // Does nothing here. You should probably update your UI now.
    }
    
    @objc func willRemoveStore(_ notification: Notification) {
        // Does nothing here (for now).
    }
    
    @objc func persistentStoreDidImportUbiquitousContentChanges(_ changeNotification: Notification) {
        mergeChanges(inContext: defaultContext, fromNotification: changeNotification)
    }
    
}
