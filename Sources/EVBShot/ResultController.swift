import AppKit
import AVKit
import UniformTypeIdentifiers

@MainActor
final class ResultController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    let artifact: CaptureArtifact
    private(set) var editDocument: ImageEditDocument?
    private(set) var canvas: ImageCanvas?
    private let scroll = NSScrollView()
    private let zoom = NSPopUpButton()
    private let dimensions = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let audio = NSButton(checkboxWithTitle: "Include audio", target: nil, action: nil)
    private let audioPlay = NSButton(title:"Play",target:nil,action:nil)
    private let savePath = NSButton(title: "Save & Copy Path", target: nil, action: nil)
    private let save = NSButton(title: "Save", target: nil, action: nil)
    private let cropApply = NSButton(title: "Crop", target: nil, action: nil)
    private let cropCancel = NSButton(title: "Cancel", target: nil, action: nil)
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private let deleteButton = NSButton()
    private let color = AnnotationColorButton(frame:.zero)
    private let stroke = NSPopUpButton()
    private let font = NSPopUpButton()
    private var toolButtons: [EditorTool: NSButton] = [:]
    private var actions = NSStackView()
    private var player: AVPlayer?
    private var previewTask: Task<Void,Never>?
    private var previewGenerator: AVAssetImageGenerator?
    private var playbackObservation: NSKeyValueObservation?
    private var resizeObserver: NSObjectProtocol?
    private let saveSettings: CaptureSaveSettings
    private let pasteboard: NSPasteboard
    private(set) var saveTask: Task<Void, Never>?
    var isSaving: Bool { saveTask != nil }
    private var busy: Bool { isSaving }
    private(set) var lastSavedURL: URL?
    private var savedState: ImageEditState?
    var onClose: (() -> Void)?

    init(_ artifact: CaptureArtifact, editingWorkspace: URL? = nil, saveSettings: CaptureSaveSettings = CaptureSaveSettings(), pasteboard: NSPasteboard = .general, mutePlayback:Bool = false) {
        self.artifact = artifact
        self.saveSettings = saveSettings; self.pasteboard = pasteboard
        let compact = artifact.kind != .image
        let initialSize = NSSize(width:compact ? 420 : 820,height:artifact.kind == .audio ? 150 : compact ? 270 : 580)
        let style:NSWindow.StyleMask = compact ? [.titled,.closable,.miniaturizable] : [.titled,.closable,.resizable,.miniaturizable]
        let window = EditorWindow(contentRect:CGRect(origin:.zero,size:initialSize), styleMask:style, backing:.buffered, defer:false)
        window.title = "EVB Shot"; window.titleVisibility = .hidden; window.toolbarStyle = .unifiedCompact
        window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
        if compact { window.level = .floating; window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary] }
        super.init(window:window); window.delegate = self
        if artifact.kind == .image {
            window.historyCommand = { [weak self] redo in
                guard let self, !self.busy, self.canvas?.tool != .crop else { return }
                if redo { self.redo() } else { self.undo() }
            }
        }
        if artifact.kind == .image {
            do {
                let document = try ImageEditDocument(source: artifact.url, width: artifact.width, height: artifact.height, workspace: editingWorkspace)
                editDocument = document
                let canvas = ImageCanvas(document: document, preview: artifact.preview); self.canvas = canvas
                document.onChange = { [weak self] in self?.canvas?.refresh(); self?.updateControls() }
                canvas.onInteraction = { [weak self] in self?.updateControls() }
                canvas.onError = { [weak self] in self?.status.stringValue = $0.localizedDescription }
                scroll.documentView = canvas
            } catch { status.stringValue = error.localizedDescription }
        } else {
            player = AVPlayer(url:artifact.url)
            player?.isMuted = mutePlayback
        }
        setupControls()
        let toolbar = NSToolbar(identifier:"EVBShot.Editor")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        let content = NSView(frame:CGRect(origin:.zero,size:initialSize))
        content.wantsLayer = true; content.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let main: NSView
        if artifact.kind == .image {
            scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
            scroll.drawsBackground = true; scroll.backgroundColor = .controlBackgroundColor
            main = scroll
        } else {
            let view = AVPlayerView(); view.player = player; view.controlsStyle = .inline
            if artifact.kind == .video {
                main = view
                if let overlay = view.contentOverlayView {
                    let poster = RecordingPosterView(); poster.identifier = NSUserInterfaceItemIdentifier("RecordingPoster")
                    poster.imageScaling = .scaleProportionallyUpOrDown; poster.image = artifact.preview
                    poster.translatesAutoresizingMaskIntoConstraints = false; overlay.addSubview(poster)
                    NSLayoutConstraint.activate([poster.leadingAnchor.constraint(equalTo:overlay.leadingAnchor),poster.trailingAnchor.constraint(equalTo:overlay.trailingAnchor),poster.topAnchor.constraint(equalTo:overlay.topAnchor),poster.bottomAnchor.constraint(equalTo:overlay.bottomAnchor)])
                    let play = NSButton(image:NSImage(systemSymbolName:"play.circle.fill",accessibilityDescription:"Play recording")!,target:self,action:#selector(togglePlayback))
                    play.identifier = NSUserInterfaceItemIdentifier("VideoPlayback"); play.isBordered = false; play.contentTintColor = .white
                    play.symbolConfiguration = .init(pointSize:44,weight:.regular); play.translatesAutoresizingMaskIntoConstraints = false
                    overlay.addSubview(play)
                    NSLayoutConstraint.activate([play.centerXAnchor.constraint(equalTo:overlay.centerXAnchor),play.centerYAnchor.constraint(equalTo:overlay.centerYAnchor)])
                    playbackObservation = player?.observe(\.rate,options:[.new]) { [weak poster,weak play] player,_ in
                        guard player.rate > 0 else { return }
                        Task { @MainActor in poster?.isHidden = true; play?.isHidden = true }
                    }
                    if poster.image == nil {
                        let generator = AVAssetImageGenerator(asset:AVURLAsset(url:artifact.url))
                        generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width:840,height:600)
                        previewGenerator = generator
                        previewTask = Task { [weak self, weak poster] in
                            do {
                                let frame = try await generator.image(at:.zero).image
                                guard !Task.isCancelled else { return }
                                poster?.image = NSImage(cgImage:frame,size:NSSize(width:frame.width,height:frame.height))
                            } catch {
                                if !Task.isCancelled { self?.status.stringValue = "Press Play to preview" }
                            }
                        }
                    }
                }
            } else {
                let symbol = NSImageView(image:NSImage(systemSymbolName:"waveform",accessibilityDescription:"Audio recording")!)
                symbol.contentTintColor = .secondaryLabelColor; symbol.symbolConfiguration = .init(pointSize:30,weight:.regular)
                symbol.heightAnchor.constraint(equalToConstant:64).isActive = true
                audioPlay.target = self; audioPlay.action = #selector(togglePlayback); audioPlay.bezelStyle = .rounded
                audioPlay.identifier = NSUserInterfaceItemIdentifier("AudioPlayback")
                audioPlay.image = NSImage(systemSymbolName:"play.fill",accessibilityDescription:nil); audioPlay.imagePosition = .imageLeading
                let audioCard = NSStackView(views:[symbol,audioPlay]); audioCard.orientation = .vertical; audioCard.spacing = 8
                audioCard.alignment = .centerX
                playbackObservation = player?.observe(\.rate,options:[.new]) { [weak self] player,_ in
                    let playing = player.rate > 0
                    Task { @MainActor in
                        self?.audioPlay.title = playing ? "Pause" : "Play"
                        self?.audioPlay.image = NSImage(systemSymbolName:playing ? "pause.fill" : "play.fill",accessibilityDescription:nil)
                    }
                }
                main = audioCard
            }
        }
        let footer = NSStackView(); footer.spacing = 12; footer.alignment = .centerY
        footer.edgeInsets = NSEdgeInsets(top:0,left:14,bottom:0,right:14)
        if artifact.kind == .image { footer.addArrangedSubview(zoom) }
        if artifact.kind == .video && artifact.hasAudio { audio.state = .on; footer.addArrangedSubview(audio) }
        dimensions.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular); dimensions.textColor = .secondaryLabelColor
        dimensions.lineBreakMode = .byTruncatingTail; dimensions.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        footer.addArrangedSubview(dimensions)
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow,for:.horizontal); footer.addArrangedSubview(spacer)
        status.font = .systemFont(ofSize:11); status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingMiddle
        status.setContentCompressionResistancePriority(.defaultLow,for:.horizontal); footer.addArrangedSubview(status)
        let reveal = NSButton(image:NSImage(systemSymbolName:"folder",accessibilityDescription:"Show capture in Finder")!,target:self,action:#selector(revealDraft))
        reveal.bezelStyle = .inline; reveal.isBordered = false; reveal.toolTip = "Show capture in Finder"; footer.addArrangedSubview(reveal)
        main.translatesAutoresizingMaskIntoConstraints = false; footer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(main); content.addSubview(footer)
        let available = NSScreen.underPointer.visibleFrame.insetBy(dx:16,dy:16)
        let maximum = window.contentRect(forFrameRect:available).size
        var mediaBottom = footer.topAnchor
        if let notice = artifact.notice {
            let warning = NSTextField(wrappingLabelWithString:notice)
            warning.identifier = NSUserInterfaceItemIdentifier("CaptureWarning")
            warning.font = .systemFont(ofSize:11); warning.textColor = .systemOrange
            warning.translatesAutoresizingMaskIntoConstraints = false; warning.preferredMaxLayoutWidth = compact ? 392 : 740
            content.addSubview(warning)
            NSLayoutConstraint.activate([
                warning.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:14),
                warning.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-14),
                warning.bottomAnchor.constraint(equalTo:footer.topAnchor,constant:-8)
            ])
            mediaBottom = warning.topAnchor
        }
        NSLayoutConstraint.activate([
            main.leadingAnchor.constraint(equalTo:content.leadingAnchor), main.trailingAnchor.constraint(equalTo:content.trailingAnchor),
            main.topAnchor.constraint(equalTo:content.topAnchor), main.bottomAnchor.constraint(equalTo:mediaBottom),
            footer.leadingAnchor.constraint(equalTo:content.leadingAnchor), footer.trailingAnchor.constraint(equalTo:content.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo:content.bottomAnchor), footer.heightAnchor.constraint(equalToConstant:34),
            content.widthAnchor.constraint(greaterThanOrEqualToConstant:min(compact ? initialSize.width : 700,maximum.width)),
            content.widthAnchor.constraint(lessThanOrEqualToConstant:min(compact ? initialSize.width : 1100,maximum.width)),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant:min(compact ? initialSize.height : 380,maximum.height)),
            content.heightAnchor.constraint(lessThanOrEqualToConstant:min(compact ? initialSize.height : maximum.height,maximum.height))
        ])
        window.contentView = content
        window.setContentSize(NSSize(width:min(initialSize.width,maximum.width),height:min(initialSize.height,maximum.height)))
        let size = window.frame.size
        window.setFrameOrigin(compact ? CGPoint(x:available.maxX-size.width,y:available.minY) : CGPoint(x:available.midX-size.width/2,y:available.midY-size.height/2))
        resizeObserver = NotificationCenter.default.addObserver(forName:NSView.frameDidChangeNotification,object:scroll.contentView,queue:.main) { [weak self] _ in
            Task { @MainActor in self?.canvas?.relayout(); self?.updateControls() }
        }
        scroll.contentView.postsFrameChangedNotifications = true
        content.layoutSubtreeIfNeeded(); canvas?.relayout(); updateControls()
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
    private func setupControls() {
        for tool in EditorTool.allCases {
            let button = NSButton(image:NSImage(systemSymbolName:tool.symbol,accessibilityDescription:tool.rawValue)!,target:self,action:#selector(toolClicked))
            button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue); button.toolTip = tool.rawValue
            button.setAccessibilityLabel(tool.rawValue); button.setButtonType(.pushOnPushOff); button.bezelStyle = .texturedRounded
            button.widthAnchor.constraint(equalToConstant:30).isActive = true
            toolButtons[tool] = button
        }
        color.color = MarkColor.red.nsColor; color.colorChanged = { [weak self] in self?.styleChanged() }
        color.widthAnchor.constraint(equalToConstant:30).isActive = true; color.heightAnchor.constraint(equalToConstant:26).isActive = true
        color.setAccessibilityLabel("Annotation color")
        stroke.addItems(withTitles:["2 px","4 px","6 px","10 px","16 px"]); stroke.selectItem(at:2)
        stroke.target = self; stroke.action = #selector(styleChanged); stroke.setAccessibilityLabel("Line thickness")
        font.addItems(withTitles:["16 pt","24 pt","32 pt","48 pt","64 pt","96 pt"]); font.selectItem(at:3)
        font.target = self; font.action = #selector(styleChanged); font.setAccessibilityLabel("Text size")
        for (button,symbol,label,action) in [(undoButton,"arrow.uturn.backward","Undo",#selector(undo)),(redoButton,"arrow.uturn.forward","Redo",#selector(redo)),(deleteButton,"trash","Delete annotation",#selector(deleteMark))] {
            button.image = NSImage(systemSymbolName:symbol,accessibilityDescription:label); button.target = self; button.action = action
            button.toolTip = label; button.setAccessibilityLabel(label); button.bezelStyle = .texturedRounded
        }
        zoom.addItems(withTitles:["Fit","Fit width","50%","100%","200%","400%"])
        if artifact.height > artifact.width * 3 { zoom.selectItem(at:1) }
        zoom.target = self; zoom.action = #selector(zoomChanged); zoom.controlSize = .small
        zoom.setAccessibilityLabel("Zoom")
        savePath.target = self; savePath.action = #selector(saveAndCopy); savePath.bezelStyle = .rounded; savePath.bezelColor = .controlAccentColor
        save.target = self; save.action = #selector(saveOnly); save.bezelStyle = .rounded
        cropApply.target = self; cropApply.action = #selector(applyCrop); cropApply.bezelStyle = .rounded; cropApply.bezelColor = .controlAccentColor
        cropCancel.target = self; cropCancel.action = #selector(cancelCrop); cropCancel.bezelStyle = .rounded
        actions = NSStackView(views:[save,savePath,cropCancel,cropApply]); actions.spacing = 8
    }
    func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar) -> [NSToolbarItem.Identifier] {
        var ids: [NSToolbarItem.Identifier] = []
        if artifact.kind == .image { ids = [NSToolbarItem.Identifier("tools"), NSToolbarItem.Identifier("style"), NSToolbarItem.Identifier("history")] }
        ids.append(.flexibleSpace); ids.append(NSToolbarItem.Identifier("save")); return ids
    }
    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }
    func toolbar(_ toolbar:NSToolbar,itemForItemIdentifier id:NSToolbarItem.Identifier,willBeInsertedIntoToolbar:Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier:id)
        switch id.rawValue {
        case "tools": item.view = NSStackView(views:EditorTool.allCases.compactMap { toolButtons[$0] }); item.label = "Annotation tools"
        case "style": item.view = NSStackView(views:[color,stroke,font]); item.label = "Style"
        case "history": item.view = NSStackView(views:[undoButton,redoButton,deleteButton]); item.label = "History"
        case "save": item.view = actions; item.label = "Save"
        default:return nil
        }
        if id.rawValue == "save" { item.visibilityPriority = .high }
        return item
    }
    func updateControls() {
        // Keep the displayed toolbar stable while export runs. The window blocks
        // input until it closes or a failed save restores editing.
        guard !busy else { return }
        if let document = editDocument, let canvas {
            let rect = canvas.pendingCrop ?? document.state.crop
            dimensions.stringValue = "\(Int(rect.width).formatted()) × \(Int(rect.height).formatted()) px"
            let cropping = canvas.tool == .crop
            toolButtons.forEach { $0.value.state = $0.key == canvas.tool ? .on : .off; $0.value.isEnabled = !busy }
            save.isHidden = cropping; savePath.isHidden = cropping; cropApply.isHidden = !cropping; cropCancel.isHidden = !cropping
            cropApply.isEnabled = rect.width >= 2 && rect.height >= 2
            if let mark = canvas.selectedMark {
                color.color = mark.color.nsColor; canvas.color = mark.color; canvas.thickness = mark.thickness; canvas.fontSize = mark.fontSize
                stroke.selectItem(at:[2,4,6,10,16].firstIndex(of:Int(mark.thickness)) ?? 2)
                font.selectItem(at:[16,24,32,48,64,96].firstIndex(of:Int(mark.fontSize)) ?? 3)
            }
            font.isHidden = canvas.tool != .text && canvas.selectedMark?.kind != .text
            stroke.isHidden = !font.isHidden
            color.isEnabled = !cropping && !busy; font.isEnabled = !busy; stroke.isEnabled = !busy
            undoButton.isEnabled = document.history.canUndo && !cropping && !busy; redoButton.isEnabled = document.history.canRedo && !cropping && !busy
            deleteButton.isEnabled = canvas.selectedMark != nil && !cropping && !busy
            window?.isDocumentEdited = document.state != (savedState ?? ImageEditState(crop:CGRect(x:0,y:0,width:document.width,height:document.height)))
            if let error = document.persistenceError { status.stringValue = "Cannot keep draft edits: \(error.localizedDescription)" }
            else if cropping { status.stringValue = "Drag the crop handles, then choose Crop" }
            else if status.stringValue.hasPrefix("Drag the crop") { status.stringValue = "" }
        } else {
            dimensions.stringValue = artifact.kind == .audio ? "Audio recording · AAC" : "\(artifact.width.formatted()) × \(artifact.height.formatted()) px"
            cropApply.isHidden = true; cropCancel.isHidden = true
        }
        savePath.isEnabled = !busy; save.isEnabled = !busy
    }
    @objc private func toolClicked(_ sender:NSButton) {
        guard let id = sender.identifier?.rawValue, let tool = EditorTool(rawValue:id) else { return }
        canvas?.setTool(tool); updateControls()
    }
    @objc private func styleChanged() {
        guard !busy else { return }
        canvas?.color = MarkColor(color.color); canvas?.thickness = CGFloat([2,4,6,10,16][stroke.indexOfSelectedItem])
        canvas?.fontSize = CGFloat([16,24,32,48,64,96][font.indexOfSelectedItem]); canvas?.updateStyle()
    }
    @objc private func zoomChanged() { canvas?.setZoom(zoom.indexOfSelectedItem) }
    @objc private func undo() { canvas?.commitText(); editDocument?.history.undo(); updateControls() }
    @objc private func redo() { canvas?.commitText(); editDocument?.history.redo(); updateControls() }
    @objc private func deleteMark() { canvas?.deleteSelection() }
    @objc private func applyCrop() { canvas?.applyCrop(); updateControls() }
    @objc private func cancelCrop() { canvas?.setTool(.select); updateControls() }
    @objc private func saveAndCopy() { saveCapture(copy:true) }
    @objc private func togglePlayback() {
        guard let player else { return }
        if player.rate > 0 { player.pause(); return }
        let duration = player.currentItem?.duration.seconds ?? .nan
        if duration.isFinite, duration > 0, player.currentTime().seconds >= duration - 0.1 {
            player.seek(to:.zero,toleranceBefore:.zero,toleranceAfter:.zero) { [weak player] finished in if finished { player?.play() } }
        } else { player.play() }
    }
    @objc private func saveOnly() { saveCapture(copy:false) }
    @objc private func revealDraft() { NSWorkspace.shared.activateFileViewerSelecting([lastSavedURL ?? artifact.url]) }
    func windowShouldClose(_ sender:NSWindow) -> Bool {
        canvas?.commitText()
        if busy { return false }
        if let error = editDocument?.persistenceError {
            let alert = NSAlert(); alert.messageText = "These edits could not be kept in Drafts."
            alert.informativeText = "Keep the editor open to save your work. \(error.localizedDescription)"
            alert.addButton(withTitle:"Keep Open"); alert.addButton(withTitle:"Discard Edits")
            return alert.runModal() == .alertSecondButtonReturn
        }
        return true
    }
    func windowWillClose(_ notification:Notification) {
        previewTask?.cancel(); previewTask = nil; previewGenerator?.cancelAllCGImageGeneration(); previewGenerator = nil; playbackObservation = nil
        canvas?.commitText(); color.detachPanel(); player?.pause(); player = nil
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        onClose?()
    }
    private func saveCapture(copy:Bool) {
        guard !busy else { return }
        canvas?.commitText()
        guard let window else { return }
        let folder = saveSettings.folder
        let includeAudio = artifact.kind != .video || audio.state == .on || !artifact.hasAudio
        canvas?.editingEnabled = false
        (window as? EditorWindow)?.interactionBlocked = true
        status.stringValue = "Saving…"
        saveTask = Task { [self] in
            var succeeded = false
            defer {
                saveTask = nil; (window as? EditorWindow)?.interactionBlocked = false
                if !succeeded { canvas?.editingEnabled = true; updateControls() }
            }
            do {
                let source:URL
                if let document = editDocument { source = try await document.export() }
                else if artifact.kind == .image { source = artifact.url }
                else { source = try await MediaExport.normalized(artifact.url,includeAudio:includeAudio) }
                lastSavedURL = try await saveCaptureFile(from:source,toFolder:folder,kind:artifact.kind,copyFilePath:copy,pasteboard:pasteboard)
                savedState = editDocument?.state; window.isDocumentEdited = false
                succeeded = true
                window.close()
            } catch { status.stringValue = error.localizedDescription }
        }
    }
}

private final class RecordingPosterView:NSImageView {
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
}
