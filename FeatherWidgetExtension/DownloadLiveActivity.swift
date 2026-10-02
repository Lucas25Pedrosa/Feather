//
//  DownloadLiveActivity.swift
//  FeatherWidgetExtension
//

import ActivityKit
import WidgetKit
import SwiftUI

private extension DownloadPhase {
	var tint: Color {
		switch self {
		case .downloading: return .blue
		case .paused: return .orange
		case .completed: return .green
		}
	}

	var title: String {
		switch self {
		case .downloading: return "Baixando"
		case .paused: return "Pausado"
		case .completed: return "Concluído"
		}
	}
}

private func downloadNames(_ names: [String]) -> String {
	if names.isEmpty { return "Downloads" }
	if names.count == 1 { return names[0] }

	let joined = names.joined(separator: ", ")
	return joined.count > 42
		? String(joined.prefix(41)) + "…"
		: joined
}

private func formattedBytes(_ value: Int64) -> String {
	let formatter = ByteCountFormatter()
	formatter.countStyle = .binary
	formatter.allowedUnits = [.useKB, .useMB, .useGB]
	return formatter.string(fromByteCount: value)
}

private func formattedSpeed(_ value: Int64) -> String {
	value > 0 ? formattedBytes(value) + "/s" : "—"
}

struct DownloadLiveActivity: Widget {
	var body: some WidgetConfiguration {
		ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
			VStack(spacing: 10) {
				HStack {
					ZStack {
						Circle()
							.stroke(
								context.state.phase.tint.opacity(0.25),
								lineWidth: 3
							)
						Circle()
							.trim(
								from: 0,
								to: context.state.overallProgress
							)
							.stroke(
								context.state.phase.tint,
								style: StrokeStyle(
									lineWidth: 3,
									lineCap: .round
								)
							)
							.rotationEffect(.degrees(-90))
						Image(systemName: context.state.phase.icon)
							.foregroundStyle(context.state.phase.tint)
					}
					.frame(width: 30, height: 30)

					VStack(alignment: .leading, spacing: 2) {
						Text(downloadNames(context.state.appNames))
							.font(.subheadline.weight(.semibold))
							.lineLimit(1)
						Text(context.state.phase.title)
							.font(.caption)
							.foregroundStyle(context.state.phase.tint)
					}

					Spacer()

					Text("\(Int(context.state.overallProgress * 100))%")
						.font(.title3.weight(.bold))
						.monospacedDigit()
				}

				ProgressView(value: context.state.overallProgress)
					.tint(context.state.phase.tint)

				HStack {
					Text(
						context.state.phase == .downloading
							? formattedSpeed(context.state.bytesPerSecond)
							: context.state.phase.title
					)

					Spacer()

					if context.state.phase == .downloading,
					   let eta = context.state.estimatedCompletionDate {
						Text(
							timerInterval: Date()...eta,
							countsDown: true
						)
					}

					Spacer()

					if context.state.totalBytesExpected > 0 {
						Text(
							"\(formattedBytes(context.state.totalBytesDownloaded)) / \(formattedBytes(context.state.totalBytesExpected))"
						)
					}
				}
				.font(.caption2)
				.foregroundStyle(.secondary)
			}
			.padding(16)
			.activityBackgroundTint(.black.opacity(0.18))
			.activitySystemActionForegroundColor(.primary)
		} dynamicIsland: { context in
			DynamicIsland {
				DynamicIslandExpandedRegion(.center) {
					VStack(spacing: 6) {
						Text(downloadNames(context.state.appNames))
							.font(.subheadline.weight(.semibold))
							.lineLimit(1)

						ProgressView(
							value: context.state.overallProgress
						)
						.tint(context.state.phase.tint)

						HStack {
							Text(context.state.phase.title)
							Spacer()

							if context.state.phase == .downloading {
								Text(
									formattedSpeed(
										context.state.bytesPerSecond
									)
								)
							}

							Spacer()

							Text(
								"\(Int(context.state.overallProgress * 100))%"
							)
							.monospacedDigit()
						}
						.font(.caption2)
						.foregroundStyle(.secondary)
					}
				}
			} compactLeading: {
				Image(systemName: context.state.phase.icon)
					.foregroundStyle(context.state.phase.tint)
			} compactTrailing: {
				Text("\(Int(context.state.overallProgress * 100))%")
					.font(.caption2.weight(.semibold))
					.monospacedDigit()
			} minimal: {
				Image(systemName: context.state.phase.icon)
					.foregroundStyle(context.state.phase.tint)
			}
			.keylineTint(context.state.phase.tint)
		}
	}
}
