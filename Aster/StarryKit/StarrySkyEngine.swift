//
//  StarsOverlay.swift
//  StarWarsAnimations
//
//  Created by Artem Sidorenko on 9/11/15.
//  Copyright © 2015 Yalantis. All rights reserved.
//

import UIKit

class StarrySkyEngine: UIImageView {
    override class var layerClass : AnyClass {
        return CAEmitterLayer.self
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        self.setup()
    }

    required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        self.setup()
    }
    
    fileprivate var emitter: CAEmitterLayer {
        return layer as! CAEmitterLayer
    }
    
    fileprivate var particle: CAEmitterCell!
    
    func setup() {
        
        // ⚠️ 本工程改动（2026-10-11）：原版这两行是
        //        image = UIImage(named:"bj_Starry")
        //        particle.contents = UIImage(named: "spark")!.cgImage
        //    **只有第二行带 `!`**，它是这个类里唯一会**真崩**的地方 ——
        //    而本类只是背景装饰，不该具备把整页搞挂的能力。资源拿不到的三种来路都真实存在：
        //      ① Assets 里改了资源名、代码没跟着改；
        //      ② 以后把这段搬进 SPM 包 —— `UIImage(named:)` 找的是 **main bundle**，必然 nil；
        //      ③ target membership 被取消。
        //  ⇒ 统一降级：**缺图 = 少一层装饰，不崩**。
        //    ⚠️ 但**不许静默**：DEBUG 下 `assertionFailure` 炸出来（改完资源名当场就知道），
        //       Release 下才安静降级 —— 与 `SceneDelegate:51` 那句是同一套用法。
        if let background = UIImage(named: "bj_Starry") {
            image = background
        } else {
            assertionFailure("缺图片资源 bj_Starry（星空底图）—— 查 Assets.xcassets 与 target membership")
        }

        emitter.emitterMode = CAEmitterLayerEmitterMode.outline
        emitter.emitterShape = CAEmitterLayerEmitterShape.circle
        emitter.renderMode = CAEmitterLayerRenderMode.oldestFirst
        emitter.preservesDepth = true
        
        particle = CAEmitterCell()
        
        if let spark = UIImage(named: "spark")?.cgImage {
            particle.contents = spark
        } else {
            // 没有粒子图 ⇒ CAEmitterCell 什么都不画（其余配置照常走完，不会再崩）
            assertionFailure("缺图片资源 spark（粒子图）—— 查 Assets.xcassets 与 target membership")
        }
        particle.birthRate = 10

        particle.velocity = 20
        particle.velocityRange = 10
#if targetEnvironment(macCatalyst)
        particle.lifetime = 9
        particle.lifetimeRange = 0.9
        particle.scale = 0.01
        particle.scaleRange = 0.012
        particle.scaleSpeed = 0.015
#else
        if  UIDevice.current.userInterfaceIdiom == .pad {
            particle.lifetime = 10
            particle.lifetimeRange = 1
            particle.scale = 0.02
            particle.scaleRange = 0.01
            particle.scaleSpeed = 0.02
        }else{
            particle.lifetime = 50
            particle.lifetimeRange = 5
            particle.scale = 0.02
            particle.scaleRange = 0.02
            particle.scaleSpeed = 0.016
        }

#endif
        
     
        
        emitter.emitterCells = [particle]
    }
    
    var emitterTimer: Timer?
    
    override func didMoveToWindow() {
        super.didMoveToWindow()
        
        if self.window != nil {
            createTimer()
        } else if emitterTimer != nil {
            invalidate()
        }
    }
    
    func createTimer(){
        if emitterTimer == nil {
            emitterTimer = Timer.scheduledTimer(timeInterval: 2, target: self, selector: #selector(StarrySkyEngine.randomizeEmitterPosition), userInfo: nil, repeats: true)
        }
    }
    
    func invalidate(){
        if(emitterTimer != nil){
            emitterTimer?.invalidate()
            emitterTimer = nil
        }
    }
    
    @objc func randomizeEmitterPosition() {
        let sizeWidth = max(bounds.width, bounds.height)
        let radius = CGFloat(arc4random()).truncatingRemainder(dividingBy: sizeWidth)
        emitter.emitterSize = CGSize(width: radius, height: radius)
        particle.birthRate = 10 + sqrt(Float(radius))
    }
    
    override func layoutSubviews() {
        super.layoutSubviews()
        emitter.emitterPosition = self.center
        emitter.emitterSize = self.bounds.size
    }
    
    @objc func getAbsolutePath(path: String) -> String? {
        let pw = getpwuid(getuid())
        guard let home = pw?.pointee.pw_dir else {
            return nil
        }
        let homePath = FileManager.default.string(withFileSystemRepresentation: home, length: Int(strlen(home)))
        return "\(homePath)/\(path)"
    }
}
