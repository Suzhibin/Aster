//
//  File.swift
//  BaseModule
//
//  Created by Suzhibin on 2026/6/26.
//

import Foundation

extension DispatchQueue {

    /// 在主线程运行
    public class func runOnMain(_ task: @escaping () -> Void) {
        if Thread.isMainThread {
            task()
        } else {
            DispatchQueue.main.async {
                task()
            }
        }
    }
    
    public class func dispatch_later(_ time: TimeInterval, block: @escaping ()-> ()) -> Void {
        DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + time, execute: block)
    }
}
