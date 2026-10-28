import Foundation

public final class StarryServiceBus {
    public static let shared = StarryServiceBus()
    private var container: [String: Any] = [:]
    private let lock = NSLock()
    
    private init() {}
    
    public func register<T>(_ serviceProtocol: T.Type, impl: T) {
        let key = String(reflecting: serviceProtocol)
        lock.lock()
        if container.keys.contains(key) {
            #if DEBUG
            assertionFailure("⚠️ StarryServiceBus: 重复注册协议 \(key)，已忽略新实现")
            #endif
            lock.unlock()
            return
        }
        container[key] = impl
        lock.unlock()
    }
    
    public func resolve<T>(_ serviceProtocol: T.Type) -> T? {
        let key = String(reflecting: serviceProtocol)
        lock.lock()
        let result = container[key] as? T
        lock.unlock()
        #if DEBUG
        if result == nil {
            print("⚠️ StarryServiceBus: 未找到协议 \(key) 的实现，请检查注册顺序")
        }
        #endif
        return result
    }
    
    public func remove<T>(_ serviceProtocol: T.Type) {
        let key = String(reflecting: serviceProtocol)
        lock.lock()
        container.removeValue(forKey: key)
        lock.unlock()
    }
    
    public func clear() {
        lock.lock()
        container.removeAll()
        lock.unlock()
    }
}