// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0

import UIKit
import Shared
import Storage
import Common

class DownloadsPanel: UIViewController,
                      UITableViewDelegate,
                      UITableViewDataSource,
                      LibraryPanel,
                      Themeable {
    private struct UX {
        static let welcomeScreenTopPadding: CGFloat = 120
        static let welcomeScreenPadding: CGFloat = 15
        static let welcomeScreenItemWidth: CGFloat = 170
    }

    weak var libraryPanelDelegate: LibraryPanelDelegate?
    var state: LibraryPanelMainState
    var bottomToolbarItems: [UIBarButtonItem] = [UIBarButtonItem]()
    var themeManager: ThemeManager
    var themeObserver: NSObjectProtocol?
    var notificationCenter: NotificationProtocol
    private var viewModel = DownloadsPanelViewModel()
    private let logger: Logger
    private let events: [Notification.Name] = [.FileDidDownload,
                                               .PrivateDataClearedDownloadedFiles,
                                               .DynamicFontChanged]

    private lazy var emptyStateOverlayView: UIView = self.createEmptyStateOverlayView()

    lazy var tableView: UITableView = .build { [weak self] tableView in
        guard let self = self else { return }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.register(TwoLineImageOverlayCell.self,
                           forCellReuseIdentifier: TwoLineImageOverlayCell.cellIdentifier)
        tableView.register(SiteTableViewHeader.self,
                           forHeaderFooterViewReuseIdentifier: SiteTableViewHeader.cellIdentifier)
        tableView.layoutMargins = .zero
        tableView.keyboardDismissMode = .onDrag
        tableView.accessibilityIdentifier = "DownloadsTable"
        tableView.cellLayoutMarginsFollowReadableWidth = false
        if #available(iOS 15.0, *) {
            tableView.sectionHeaderTopPadding = 0.0
        }
        // Set an empty footer to prevent empty cells from appearing in the list.
        tableView.tableFooterView = UIView()
    }

    // MARK: - Lifecycle
    init(notificationCenter: NotificationProtocol = NotificationCenter.default,
         themeManager: ThemeManager = AppContainer.shared.resolve(),
         logger: Logger = DefaultLogger.shared) {
        self.notificationCenter = notificationCenter
        self.themeManager = themeManager
        self.logger = logger
        self.state = .downloads
        super.init(nibName: nil, bundle: nil)
        events.forEach { NotificationCenter.default.addObserver(self, selector: #selector(notificationReceived), name: $0, object: nil) }
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        (navigationController as? ThemedNavigationController)?.applyTheme()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        listenForThemeChange()
        applyTheme()
    }

    deinit {
        // The view might outlive this view controller thanks to animations;
        // explicitly nil out its references to us to avoid crashes. Bug 1218826.
        tableView.dataSource = nil
        tableView.delegate = nil
    }

    @objc func notificationReceived(_ notification: Notification) {
        DispatchQueue.main.async {
            self.reloadData()

            switch notification.name {
            case .FileDidDownload, .PrivateDataClearedDownloadedFiles:
                break
            case .DynamicFontChanged:
                if self.emptyStateOverlayView.superview != nil {
                    self.emptyStateOverlayView.removeFromSuperview()
                }
                self.emptyStateOverlayView = self.createEmptyStateOverlayView()
                break
            default:
                break
            }
        }
    }

    func reloadData() {
        viewModel.reloadData()

        tableView.reloadData()
        updateEmptyPanelState()
    }

    private func deleteDownloadedFile(_ downloadedFile: DownloadedFile) -> Bool {
        do {
            try FileManager.default.removeItem(at: downloadedFile.path)
            return true
        } catch let error {
            logger.log("Unable to delete downloaded file: \(error.localizedDescription)",
                       level: .warning,
                       category: .library)
        }

        return false
    }

    private func shareDownloadedFile(_ downloadedFile: DownloadedFile, indexPath: IndexPath) {
        let helper = ShareExtensionHelper(url: downloadedFile.path, tab: nil)
        let controller = helper.createActivityViewController { _, _ in }

        if let popoverPresentationController = controller.popoverPresentationController {
            guard let tableViewCell = tableView.cellForRow(at: indexPath) else { return }

            popoverPresentationController.sourceView = tableViewCell
            popoverPresentationController.sourceRect = tableViewCell.bounds
            popoverPresentationController.permittedArrowDirections = .any
        }

        present(controller, animated: true, completion: nil)
    }

    private func iconForFileExtension(_ fileExtension: String) -> UIImage? {
        if let icon = viewModel.fileExtensionIcons[fileExtension] {
            return icon
        }

        guard let icon = roundRectImageWithLabel(fileExtension, width: 29, height: 29) else { return nil }

        viewModel.fileExtensionIcons[fileExtension] = icon
        return icon
    }

    private func roundRectImageWithLabel(
        _ label: String,
        width: CGFloat,
        height: CGFloat
    ) -> UIImage? {
        let radius: CGFloat = 5.0
        let strokeWidth: CGFloat = 1.0
        let strokeColor: UIColor = themeManager.currentTheme.colors.iconSecondary
        let fontSize: CGFloat = 9.0

        UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: height), false, 0.0)
        let context = UIGraphicsGetCurrentContext()
        context?.setStrokeColor(strokeColor.cgColor)

        let rect = CGRect(x: strokeWidth / 2,
                          y: strokeWidth / 2,
                          width: width - strokeWidth,
                          height: height - strokeWidth)
        let bezierPath = UIBezierPath(roundedRect: rect, cornerRadius: radius)
        bezierPath.lineWidth = strokeWidth
        bezierPath.stroke()

        let attributedString = NSAttributedString(string: label, attributes: [
            .baselineOffset: -(strokeWidth * 2),
            .font: UIFont.systemFont(ofSize: fontSize),
            .foregroundColor: strokeColor
            ])
        let stringHeight: CGFloat = fontSize * 2
        let stringWidth = attributedString.boundingRect(with: CGSize(width: width, height: stringHeight), options: .usesLineFragmentOrigin, context: nil).size.width
        attributedString.draw(at: CGPoint(x: (width - stringWidth) / 2 + strokeWidth, y: (height - stringHeight) / 2 + strokeWidth))

        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return image
    }

    // MARK: - Empty State
    private func updateEmptyPanelState() {
        if !viewModel.hasDownloadedFiles {
            if emptyStateOverlayView.superview == nil {
                view.addSubview(emptyStateOverlayView)
                view.bringSubviewToFront(emptyStateOverlayView)

                NSLayoutConstraint.activate([
                    emptyStateOverlayView.topAnchor.constraint(equalTo: view.topAnchor),
                    emptyStateOverlayView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                    emptyStateOverlayView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
                    emptyStateOverlayView.trailingAnchor.constraint(equalTo: view.trailingAnchor)
                ])
            }
        } else {
            emptyStateOverlayView.removeFromSuperview()
        }
    }

    private func createEmptyStateOverlayView() -> UIView {
        let overlayView: UIView = .build { view in
            view.backgroundColor = self.themeManager.currentTheme.colors.layer6
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        let logoImageView: UIImageView = .build { imageView in
            imageView.image = UIImage.templateImageNamed("emptyDownloads")?.withRenderingMode(.alwaysTemplate)
            imageView.tintColor = self.themeManager.currentTheme.colors.iconSecondary
        }
        let welcomeLabel: UILabel = .build { label in
            label.text = .DownloadsPanelEmptyStateTitle
            label.textAlignment = .center
            label.font = DynamicFontHelper.defaultHelper.DeviceFontLight
            label.textColor = self.themeManager.currentTheme.colors.textSecondary
            label.numberOfLines = 0
            label.adjustsFontSizeToFitWidth = true
        }

        overlayView.addSubview(logoImageView)
        overlayView.addSubview(welcomeLabel)

        NSLayoutConstraint.activate([
            logoImageView.topAnchor.constraint(equalTo: overlayView.topAnchor, constant: UX.welcomeScreenTopPadding),
            logoImageView.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
            logoImageView.heightAnchor.constraint(equalToConstant: 60),
            logoImageView.widthAnchor.constraint(equalToConstant: 60),

            welcomeLabel.centerXAnchor.constraint(equalTo: overlayView.centerXAnchor),
            welcomeLabel.topAnchor.constraint(equalTo: logoImageView.bottomAnchor, constant: UX.welcomeScreenPadding),
            welcomeLabel.widthAnchor.constraint(equalToConstant: UX.welcomeScreenItemWidth)
        ])

        return overlayView
    }

    // MARK: - TableView Delegate / DataSource
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: TwoLineImageOverlayCell.cellIdentifier,
                                                 for: indexPath) as! TwoLineImageOverlayCell

        return configureDownloadedFile(cell, for: indexPath)
    }

    func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        if let header = view as? UITableViewHeaderFooterView {
            header.textLabel?.textColor = themeManager.currentTheme.colors.textPrimary
            header.contentView.backgroundColor = themeManager.currentTheme.colors.layer1
        }
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        guard viewModel.hasDownloadedItem(for: section) else { return 0 }

        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard viewModel.hasDownloadedItem(for: section),
              let headerView = tableView.dequeueReusableHeaderFooterView(withIdentifier: SiteTableViewHeader.cellIdentifier) as?
                SiteTableViewHeader
        else { return nil }

        let title = viewModel.headerTitle(for: section) ?? ""

        let headerViewModel = SiteTableViewHeaderModel(title: title,
                                                       isCollapsible: false,
                                                       collapsibleState: nil)
        headerView.configure(headerViewModel)
        headerView.showBorder(for: .top, !viewModel.isFirstSection(section))
        headerView.applyTheme(theme: themeManager.currentTheme)

        return headerView
    }

    func configureDownloadedFile(_ cell: UITableViewCell, for indexPath: IndexPath) -> UITableViewCell {
        if let downloadedFile = viewModel.downloadedFileForIndexPath(indexPath),
           let cell = cell as? TwoLineImageOverlayCell {
            cell.titleLabel.text = downloadedFile.filename
            cell.descriptionLabel.text = downloadedFile.formattedSize
            cell.leftImageView.image = iconForFileExtension(downloadedFile.fileExtension)
            cell.applyTheme(theme: themeManager.currentTheme)
        }
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        if let downloadedFile = viewModel.downloadedFileForIndexPath(indexPath) {
            TelemetryWrapper.recordEvent(category: .action, method: .tap, object: .download, value: .downloadsPanel)

            if downloadedFile.mimeType == MIMEType.Calendar {
                let docController = UIDocumentInteractionController(url: downloadedFile.path)
                docController.delegate = self
                docController.presentPreview(animated: true)
                return
            }

            guard downloadedFile.canShowInWebView else {
                shareDownloadedFile(downloadedFile, indexPath: indexPath)
                return
            }
            libraryPanelDelegate?.libraryPanel(didSelectURL: downloadedFile.path, visitType: VisitType.typed)
        }
    }

    func numberOfSections(in tableView: UITableView) -> Int {
        return 4
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return viewModel.getNumberOfItems(for: section)
    }

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let deleteAction = UIContextualAction(style: .destructive, title: .DownloadsPanelDeleteTitle) { [weak self] (_, _, completion) in
            guard let strongSelf = self else { completion(false); return }

            if let downloadedFile = strongSelf.viewModel.downloadedFileForIndexPath(indexPath),
               strongSelf.deleteDownloadedFile(downloadedFile) {
                strongSelf.tableView.beginUpdates()
                strongSelf.viewModel.removeDownloadedFile(downloadedFile)
                strongSelf.tableView.deleteRows(at: [indexPath], with: .right)
                strongSelf.tableView.endUpdates()
                strongSelf.updateEmptyPanelState()
                TelemetryWrapper.recordEvent(category: .action, method: .delete, object: .download, value: .downloadsPanel)
                completion(true)
            } else {
                completion(false)
            }
        }

        let shareAction = UIContextualAction(style: .normal, title: .DownloadsPanelShareTitle) { [weak self] (_, view, completion) in
            guard let strongSelf = self else { completion(false); return }

            view.backgroundColor = strongSelf.view.tintColor
            if let downloadedFile = strongSelf.viewModel.downloadedFileForIndexPath(indexPath) {
                strongSelf.shareDownloadedFile(downloadedFile, indexPath: indexPath)
                TelemetryWrapper.recordEvent(category: .action, method: .share, object: .download, value: .downloadsPanel)
                completion(true)
            } else {
                completion(false)
            }
        }

        return UISwipeActionsConfiguration(actions: [deleteAction, shareAction])
    }

    func applyTheme() {
        emptyStateOverlayView.removeFromSuperview()
        emptyStateOverlayView = createEmptyStateOverlayView()
        updateEmptyPanelState()

        tableView.backgroundColor = themeManager.currentTheme.colors.layer6
        tableView.separatorColor = themeManager.currentTheme.colors.borderPrimary

        reloadData()
    }
}

// MARK: - UIDocumentInteractionControllerDelegate
extension DownloadsPanel: UIDocumentInteractionControllerDelegate {
    func documentInteractionControllerViewControllerForPreview(_ controller: UIDocumentInteractionController) -> UIViewController {
        return self
    }
}
