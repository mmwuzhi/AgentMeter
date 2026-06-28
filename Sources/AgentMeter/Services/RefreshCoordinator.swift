import Foundation

/// Drives periodic + manual refresh of both providers and publishes into the view model.
@MainActor
final class RefreshCoordinator {
    private let viewModel: AppViewModel
    private let codex = CodexService()
    private let claude = ClaudeService()
    private var timer: Timer?

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
    }

    func start() {
        Task { await PricingService.shared.refresh() }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        guard !viewModel.isRefreshing else { return }
        viewModel.isRefreshing = true
        Task {
            async let codexState = codex.fetch()
            async let claudeState = claude.fetch()
            let (c, cl) = await (codexState, claudeState)
            viewModel.codex = c
            viewModel.claude = cl
            viewModel.lastRefresh = Date()
            viewModel.isRefreshing = false
        }
    }
}
