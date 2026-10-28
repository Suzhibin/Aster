//
//  AIAttachmentPhotoGrid.swift
//  AIModule
//
//  「+」面板里那块**最近照片网格**：把入口那一行下面的空白用起来，
//  用户点一格 = 直接把这张图加进待发附件（等价于从 `PHPicker` 里选了一张）。
//

import UIKit
import Photos
import SnapKit
// 🔴 `L()` 在 `AICore`（本地化词表，见 `AILocalization.swift`）。
import AICore

/// 最近照片网格。
///
/// ## 位置与尺寸
/// 占「入口那一行」到「面板底部安全区」之间的**全部空白**。
/// ⚠️ 面板总高是**绑死系统键盘**的常量（见 `InputToolbar.panelTotalHeight`），
/// 所以这块的可视高度随机型变 —— 全面屏 ≈ 336−100−34 = 202pt，带 Home 键 ≈ 260−100−0 = 160pt。
/// 因此行列数必须**按实际尺寸算**，不能写死 2×4：
/// 两行装得下（每格 ≥ `minimumItemHeight`）就两行，否则退成一行。
///
/// 而且**不做滚动**：格数正好按可视容量算，铺满为止（`isScrollEnabled = false`）。
/// 这样也顺手躲开一个坑 —— 面板就在输入栏里，网格要是能滚，纵向手势会和
/// 「拖动列表收起面板」抢；横向又会和输入栏那套手势打架。看更多照片走「相册」按钮。
///
/// ## 三种授权态各有各的样子
/// | 授权态 | 界面 |
/// |---|---|
/// | 还没问过 | 首次打开面板时问一次，答完再建列表 |
/// | 全部 / 部分 | 铺最近若干张；`limited` 时**末尾多一格「管理」**（系统那个「管理已选照片」列表） |
/// | 拒绝 | 一行「去设置开启相册权限」的文字按钮 |
///
/// ⚠️ 拒绝态**故意不是整块消失**：全隐藏的话用户永远不知道这块能放图，
/// 而 App 内又没有任何提示 —— 功能等于不存在。留一行字，成本极低，还能自助恢复。
final class AIAttachmentPhotoGrid: UIView {

    /// 点了一张缩略图（宿主负责：取整图 → 落盘 → 进待发区）
    var onPickAsset: ((PHAsset) -> Void)?

    // MARK: - 尺寸口径

    /// 尺寸口径。
    /// ⚠️ `fileprivate` 而不是 `private`：下面的格子要共用 `cornerRadius`，
    /// 免得圆角在网格和格子里各写一份、改一处漏一处。
    fileprivate enum Metrics {
        /// 格子之间、以及格子与边缘的间距
        static let spacing: CGFloat = 8
        static let horizontalInset: CGFloat = 16
        static let topInset: CGFloat = 6
        static let bottomInset: CGFloat = 2
        /// 期望的格子宽度：据此反推一行放几个（4 个 ≈ 88pt，和微信/DeepSeek 那一档相当）
        static let preferredItemWidth: CGFloat = 88
        static let minimumItemHeight: CGFloat = 64
        /// 一次最多取多少张。比可视容量多取一些，换机型/横竖屏时不用重新 fetch
        static let maxFetchCount = 40
        static let cornerRadius: CGFloat = 8

        static func columns(forWidth width: CGFloat) -> Int {
            let usable = max(0, width - horizontalInset * 2)
            let raw = Int((usable + spacing) / (preferredItemWidth + spacing))
            return min(8, max(4, raw))
        }

        /// 按当前可视区域算出「格子尺寸 + 列数 + 行数」——三者一起算，避免口径分家。
        static func layout(in bounds: CGRect) -> (item: CGSize, columns: Int, rows: Int) {
            let columns = columns(forWidth: bounds.width)

            let usableWidth = bounds.width - horizontalInset * 2 - spacing * CGFloat(columns - 1)
            let itemWidth = max(1, usableWidth / CGFloat(columns))

            let usableHeight = bounds.height - topInset - bottomInset
            // 两行放得下就两行；面板矮（带 Home 键机型）时退成一行，别硬塞成两条细缝
            let rows = (usableHeight - spacing) / 2 >= minimumItemHeight ? 2 : 1
            var itemHeight = max(1, (usableHeight - spacing * CGFloat(rows - 1)) / CGFloat(rows))
            // 退成一行时高度是「剩多少给多少」，可能被拉成一根竖条 —— 按宽度的 1.4 倍封顶，
            // 宁可在下方留点白
            if rows == 1 {
                itemHeight = min(itemHeight, itemWidth * 1.4)
            }

            return (CGSize(width: floor(itemWidth), height: floor(itemHeight)), columns, rows)
        }
    }

    // MARK: - 状态

    private var assets: [PHAsset] = []
    private var authState: PhotosAuthState = .notDetermined
    /// 已经跑过一次授权流程（避免每次开面板都问）
    private var didLoadOnce = false
    private var isObservingLibrary = false

    /// 当前行列（`layoutSubviews` 里算出来，`numberOfItems` 要用）
    private var columns = 4
    private var rows = 2

    private var showsManageCell: Bool { authState == .limited }

    // MARK: - 子视图

    private lazy var flowLayout: UICollectionViewFlowLayout = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .vertical
        layout.minimumLineSpacing = Metrics.spacing
        layout.minimumInteritemSpacing = Metrics.spacing
        layout.sectionInset = UIEdgeInsets(top: Metrics.topInset,
                                           left: Metrics.horizontalInset,
                                           bottom: Metrics.bottomInset,
                                           right: Metrics.horizontalInset)
        return layout
    }()

    private lazy var collectionView: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: flowLayout)
        view.backgroundColor = .clear
        view.isScrollEnabled = false          // 格数按可视容量算好，永远是「刚好铺满」
        view.clipsToBounds = true
        view.dataSource = self
        view.delegate = self
        view.register(AIAttachmentPhotoCell.self,
                      forCellWithReuseIdentifier: AIAttachmentPhotoCell.reuseID)
        return view
    }()

    /// 权限被拒时那行引导（拒绝态的唯一出路）
    private lazy var hintButton: UIButton = {
        let button = UIButton(type: .custom)
        button.setTitle(L("去「设置」开启相册权限，这里就能选图"), for: .normal)
        button.setTitleColor(.systemBlue, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 13)
        button.titleLabel?.textAlignment = .center
        button.backgroundColor = .secondarySystemFill
        button.layer.cornerRadius = 10
        button.isHidden = true
        button.addTarget(self, action: #selector(openSettingsTapped), for: .touchUpInside)
        return button
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        addSubview(collectionView)
        addSubview(hintButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if isObservingLibrary {
            PHPhotoLibrary.shared().unregisterChangeObserver(self)
        }
    }

    // MARK: - 对外

    /// 面板每次打开时叫一次（**幂等**）。
    ///
    /// 只有「第一次」会弹权限窗；之后授权态没变就直接返回 ——
    /// 相册有变更（用户自己拍/存了图、或在「管理」里改选了照片）会走
    /// `photoLibraryDidChange`，不用靠反复重建来刷新。
    func reloadIfNeeded() {
        startObservingLibraryIfNeeded()

        let current = PhotosLibraryService.shared.authState
        if didLoadOnce, current == authState { return }
        didLoadOnce = true

        guard current == .notDetermined else {
            authState = current
            rebuild()
            return
        }
        // 首次打开面板 → 问一次权限；用户答完再建列表（弹窗期间这块就是空的）
        PhotosLibraryService.shared.requestAuthorization { [weak self] state in
            guard let self = self else { return }
            self.authState = state
            self.rebuild()
        }
    }

    // MARK: - 布局

    override func layoutSubviews() {
        super.layoutSubviews()
        collectionView.frame = bounds

        let hintHeight: CGFloat = 40
        hintButton.frame = CGRect(x: Metrics.horizontalInset,
                                  y: max(0, (bounds.height - hintHeight) / 2 - 10),
                                  width: max(0, bounds.width - Metrics.horizontalInset * 2),
                                  height: hintHeight)

        guard bounds.width > 0, bounds.height > 0 else { return }
        let layout = Metrics.layout(in: bounds)

        // 行列变了 → 可视容量变了 → 显示的格数也要跟着变
        if columns != layout.columns || rows != layout.rows {
            columns = layout.columns
            rows = layout.rows
            collectionView.reloadData()
        }
        // `itemSize` 变了才动 layout：layoutSubviews 里改布局会再来一轮，
        // 不判等就会变成死循环
        if flowLayout.itemSize != layout.item {
            flowLayout.itemSize = layout.item
            flowLayout.invalidateLayout()
        }
    }

    // MARK: - 建列表

    private func rebuild() {
        assets = authState.canRead
            ? PhotosLibraryService.shared.fetchRecentImages(limit: Metrics.maxFetchCount)
            : []
        collectionView.isHidden = !authState.canRead
        hintButton.isHidden = (authState != .denied)
        collectionView.reloadData()
        setNeedsLayout()
    }

    /// 相册变更（新增照片、「管理」里改选、iCloud 同步完成…）→ 重建。
    /// 回调在**后台队列**，而且 `PHFetchResult` 与那次 change 绑定、不能跨线程用 ——
    /// 所以不去解析 `changeInstance`，直接回主线程重新 fetch 一份，简单且不会错。
    private func startObservingLibraryIfNeeded() {
        guard !isObservingLibrary else { return }
        isObservingLibrary = true
        PHPhotoLibrary.shared().register(self)
    }

    /// 当前可视容量（格子总数）
    private var capacity: Int { max(0, columns * rows) }

    /// 实际要显示的格数。
    /// `limited` 时末尾留一格给「管理」—— **哪怕一张都没勾也留着**，
    /// 否则「只授权了 0 张」的用户会看到一块全空、连恢复入口都没有的网格。
    private var visibleCount: Int {
        guard showsManageCell else { return min(assets.count, capacity) }
        return min(assets.count, max(0, capacity - 1)) + 1
    }

    private var photoCount: Int { visibleCount - (showsManageCell ? 1 : 0) }

    // MARK: - 回调

    @objc private func openSettingsTapped() {
        PhotosLibraryService.shared.openSystemSettings()
    }

    private func presentLimitedPicker() {
        guard let host = nearestViewController else { return }
        PhotosLibraryService.shared.presentLimitedLibraryPicker(from: host)
    }

    /// 顺着响应链找宿主 VC —— `presentLimitedLibraryPicker(from:)` 必须要一个 VC，
    /// 而网格挂在「输入栏 → VC.view」这条链上，一路 `next` 上去就能拿到。
    private var nearestViewController: UIViewController? {
        var responder: UIResponder? = self
        while let next = responder?.next {
            if let viewController = next as? UIViewController { return viewController }
            responder = next
        }
        return nil
    }
}

// MARK: - 数据源 / 代理

extension AIAttachmentPhotoGrid: UICollectionViewDataSource, UICollectionViewDelegate {

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        visibleCount
    }

    func collectionView(_ collectionView: UICollectionView,
                        cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: AIAttachmentPhotoCell.reuseID,
                                                      for: indexPath)
        guard let photoCell = cell as? AIAttachmentPhotoCell else { return cell }

        if showsManageCell, indexPath.item >= photoCount {
            photoCell.configureAsManage()
        } else if assets.indices.contains(indexPath.item) {
            photoCell.configure(with: assets[indexPath.item])
        }
        return photoCell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        if showsManageCell, indexPath.item >= photoCount {
            presentLimitedPicker()
            return
        }
        guard assets.indices.contains(indexPath.item) else { return }
        onPickAsset?(assets[indexPath.item])
    }
}

// MARK: - 相册变更

extension AIAttachmentPhotoGrid: PHPhotoLibraryChangeObserver {

    /// ⚠️ `nonisolated` 不能省：`PHPhotoLibraryChangeObserver` 是**老 ObjC 协议**，
    /// 系统可能在**任意线程**回调；而本工程开了 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，
    /// 类的默认隔离是 MainActor → 方法默认就成了 MainActor 隔离，
    /// 会报 `main actor-isolated conformance ... cannot be used in nonisolated context`
    /// （Swift 6 语言模式下直接是 error）。
    ///
    /// 标 `nonisolated` 是**如实描述**：本方法可以在任何线程被调用 ——
    /// 所以下面第一件事就是切回主线程再动 UI，别在这里直接碰视图。
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuild()
        }
    }
}

// MARK: - 格子

/// 一个格子：照片缩略图，或（`limited` 态下）末尾那个「管理」入口。
///
/// ⚠️ 缩略图请求**必须在 `layoutSubviews` 里发**：cell 从复用池里出来时 bounds 可能还是 0，
/// 在 `configure` 里按 0 尺寸发请求会拿到空图。这里用「已请求的像素尺寸」做判据，
/// 尺寸没变就不重复发（`reloadData` 会走 `prepareForReuse`，所以会重发一次，但系统有缓存）。
private final class AIAttachmentPhotoCell: UICollectionViewCell {

    static let reuseID = "AIAttachmentPhotoCell"

    private let imageView = UIImageView()
    private let manageStack = UIStackView()
    private let manageIcon = UIImageView()
    private let manageLabel = UILabel()

    private var asset: PHAsset?
    private var requestID: PHImageRequestID?
    private var requestedPixelSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = true
        contentView.layer.cornerRadius = AIAttachmentPhotoGrid.Metrics.cornerRadius
        contentView.backgroundColor = .secondarySystemFill

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = .secondarySystemFill
        contentView.addSubview(imageView)
        imageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        manageIcon.image = UIImage(systemName: "photo.on.rectangle.angled")
        manageIcon.tintColor = .secondaryLabel
        manageIcon.contentMode = .scaleAspectFit
        manageIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 20)

        manageLabel.text = L("管理")
        manageLabel.font = .systemFont(ofSize: 12)
        manageLabel.textColor = .secondaryLabel
        manageLabel.textAlignment = .center

        manageStack.axis = .vertical
        manageStack.alignment = .center
        manageStack.spacing = 6
        manageStack.isHidden = true
        manageStack.isUserInteractionEnabled = false
        manageStack.addArrangedSubview(manageIcon)
        manageStack.addArrangedSubview(manageLabel)
        contentView.addSubview(manageStack)
        manageStack.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        manageIcon.snp.makeConstraints { make in
            make.width.height.equalTo(22)
        }

        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { cancelCurrentRequest() }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancelCurrentRequest()
        asset = nil
        requestedPixelSize = .zero
        imageView.image = nil
        imageView.isHidden = false
        manageStack.isHidden = true
    }

    func configure(with asset: PHAsset) {
        self.asset = asset
        imageView.image = nil
        imageView.isHidden = false
        manageStack.isHidden = true
        requestedPixelSize = .zero
        accessibilityLabel = L("照片")
        // 尺寸没变的话这里就会命中缓存判据、不发重复请求
        loadThumbnailIfNeeded()
    }

    func configureAsManage() {
        asset = nil
        cancelCurrentRequest()
        requestedPixelSize = .zero
        imageView.image = nil
        imageView.isHidden = true
        manageStack.isHidden = false
        accessibilityLabel = L("管理已选照片")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        loadThumbnailIfNeeded()
    }

    private func loadThumbnailIfNeeded() {
        guard let asset = asset else { return }
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        let target = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard target.width >= 1, target.height >= 1, target != requestedPixelSize else { return }
        requestedPixelSize = target

        cancelCurrentRequest()
        requestID = PhotosLibraryService.shared.requestThumbnail(for: asset, targetSize: target) { [weak self] image in
            // 回调可能晚于复用：只认「还是我这张」
            guard let self = self, self.asset === asset else { return }
            self.imageView.image = image
        }
    }

    private func cancelCurrentRequest() {
        guard let id = requestID else { return }
        PhotosLibraryService.shared.cancelRequest(id)
        requestID = nil
    }
}
