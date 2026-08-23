import SwiftUI

struct WorkspaceView: View {
    @Environment(AppModel.self) private var model

    private let columns = [GridItem(.adaptive(minimum: 240), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if model.workspaceList.isEmpty {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(model.workspaceList) { ws in
                            WorkspaceCard(info: ws)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack {
            Text("共 \(model.workspaceList.count) 个")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                WorkspaceMonitor.openInFinder(Paths.dshHome(model.config.dshHome).path)
            } label: {
                Label("数据目录", systemImage: "externaldrive")
            }
            .help("在 Finder 中打开：\(Paths.dshHome(model.config.dshHome).path)")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.slash")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("暂无工作区数据")
                .font(.headline)
            Text("请先运行 DeepSeek Harness 并在客户端创建工作区")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

private struct WorkspaceCard: View {
    let info: WorkspaceInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(.tint)
                Text(info.title.isEmpty ? info.id : info.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                StatusTag(text: "\(info.sessionCount) 会话", color: .accentColor)
            }
            Text(info.path.isEmpty ? "-" : info.path)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(minHeight: 26, alignment: .top)
            HStack {
                Text("更新于 \(Format.relative(info.updatedAt))")
                    .help("更新于: \(Format.localDateTime(info.updatedAt))")
                Spacer()
                Text("创建于 \(Format.shortDate(info.createdAt))")
                    .help("创建于: \(Format.localDateTime(info.createdAt))")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .onTapGesture {
            WorkspaceMonitor.revealInFinder(info.path)
        }
        .help(info.path.isEmpty ? "" : "在 Finder 中打开 \(info.title.isEmpty ? "此工作区" : info.title)")
    }
}
