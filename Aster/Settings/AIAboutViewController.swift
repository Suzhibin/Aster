//
//  AIAboutViewController.swift
//  Aster
//
//  「关于 Aster」页 —— 2026-10-14 新建，内容对齐 Mac 的 `MacAboutSettingsView`。
//
//  ## 三段内容
//  ① **版本**（只读，右侧显示 `CFBundleShortVersionString`（+ build））；
//  ② 一句说明「这是个本地优先的客户端」（组尾灰字）；
//  ③ **源码** —— 一行可点的入口，点了交给系统浏览器（与账号弹窗那条 GitHub 同一个地址）。
//
//  ## 🔴 版本号取不到时回落 "1.0"
//  `Bundle.main` 在某些非 App 包环境下会拿不到 Info.plist ⇒ 回落成**与真机同一个值**，
//  截图才有验收意义（真机上读到的就是 `CFBundleShortVersionString`）。
//  ⚠️ 与 Mac 侧那份 `MacAboutSettingsView.versionLine` 同一个口径（各自读各自的 bundle）。
//
//  ## 🔴 GitHub 地址口径单点
//  走共享层的 `AIGitHubURL`（`AsterCore/AICore/AIAppInfo.swift`）—— ⛔ 别在本文件再写一份字符串。
//  ⚠️ 2026-10-27 用户删掉「头像 + 名称」之后，原来的单点 `AIAccountMenuViewController.gitHubURL`
//    随整个账号弹窗一起删了 ⇒ 地址挪进共享层，两端（本文件 + Mac `MacAboutSettingsView`）同源。
//

import UIKit
import SnapKit
import AICore

final class AIAboutViewController: UIViewController {

    private enum Row {
        case version
        case source

        var title: String {
            switch self {
            case .version: return L("版本")
            case .source:  return L("源码")
            }
        }
    }

    private static let cellID = "AIAboutCell"

    private var rows: [Row] { [.version, .source] }

    private lazy var tableView: UITableView = {
        let tv = UITableView(frame: .zero, style: .insetGrouped)
        tv.backgroundColor = .systemGroupedBackground
        tv.dataSource = self
        tv.delegate = self
        tv.rowHeight = 52
        tv.register(UITableViewCell.self, forCellReuseIdentifier: Self.cellID)
        return tv
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("关于 Aster")
        view.backgroundColor = .systemGroupedBackground
        view.addSubview(tableView)
        tableView.snp.makeConstraints { make in make.edges.equalToSuperview() }
    }

    // MARK: - 内容

    /// 版本号那一行。取不到就回落 `"1.0"`（见文件头）。
    private var versionText: String {
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let build = (info?["CFBundleVersion"] as? String) ?? ""
        return build.isEmpty ? version : "\(version)（\(build)）"
    }

    private func openGitHub() {
        guard let url = URL(string: AIGitHubURL) else { return }
        UIApplication.shared.open(url)
    }

    private func configure(_ cell: UITableViewCell, with row: Row) {
        var config = UIListContentConfiguration.valueCell()
        config.text = row.title
        // 🔴 字号走 `AIChromeFont`（2026-10-22 接字号档位）：显式钉文本样式，理由同
        //    `AISettingsViewController.configure` —— 吃系统默认值的部分不随档位走。
        config.textProperties.font = AIChromeFont.ui(.body)
        config.secondaryTextProperties.font = AIChromeFont.ui(.subheadline)
        switch row {
        case .version:
            config.secondaryText = versionText
            cell.selectionStyle = .none
        case .source:
            // ⚠️ 由 `AIGitHubURL` 派生（`AIGitHubDisplayName`），⛔ 别写死这串字
            config.secondaryText = AIGitHubDisplayName
            config.image = UIImage(systemName: "sparkles")
            config.imageProperties.tintColor = .systemBlue
            config.imageProperties.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 15)
            cell.selectionStyle = .default
        }
        cell.contentConfiguration = config
        cell.accessoryType = (row == .source) ? .disclosureIndicator : .none
        cell.backgroundColor = .secondarySystemGroupedBackground
    }
}

// MARK: - 列表数据源

extension AIAboutViewController: UITableViewDataSource, UITableViewDelegate {

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        // 两行都在第 0 组 —— 「版本」与「源码」本来就是同一张卡上的两行。
        rows.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: Self.cellID, for: indexPath)
        guard rows.indices.contains(indexPath.row) else { return cell }
        configure(cell, with: rows[indexPath.row])
        return cell
    }

    /// 组尾那句说明（与 Mac 卡片里的 `subtitle` 同一句话，共用同一条词表 key）。
    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        L("一个本地优先的 AI 对话客户端：会话与配置都留在本机，模型写在自己的 models.json 里。")
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard rows.indices.contains(indexPath.row) else { return }
        if rows[indexPath.row] == .source { openGitHub() }
    }
}
