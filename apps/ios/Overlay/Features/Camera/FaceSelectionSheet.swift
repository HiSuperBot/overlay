import SwiftUI
import UIKit

struct FaceSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    let controller: FaceTrackingController

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Face")
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close face selection")
            }
            .padding(.leading, 20)
            .padding(.trailing, 8)
            .padding(.top, 8)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    choiceCard(title: "Original", isSelected: controller.previewMode == .original, action: {
                        selectMode(.original)
                    }) {
                        Image(systemName: "camera")
                            .font(.system(size: 34, weight: .light))
                            .frame(height: 64)
                    }
                    choiceCard(title: "Mesh", isSelected: controller.previewMode == .mesh, action: {
                        selectMode(.mesh)
                    }) {
                        Image(systemName: "faceid")
                            .font(.system(size: 34, weight: .light))
                            .frame(height: 64)
                    }
                    ForEach(controller.avatars) { avatar in
                        choiceCard(
                            title: avatar.name,
                            isSelected: controller.previewMode == .avatar && controller.selectedAvatarID == avatar.id,
                            action: {
                                controller.selectAvatar(avatar.id)
                                controller.previewMode = .avatar
                                dismiss()
                            }
                        ) {
                            thumbnail(avatar)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
            }
        }
        .background(Color(uiColor: .secondarySystemBackground))
    }

    private func selectMode(_ mode: PreviewMode) {
        controller.previewMode = mode
        dismiss()
    }

    private func choiceCard<Artwork: View>(
        title: String, isSelected: Bool, action: @escaping () -> Void,
        @ViewBuilder artwork: () -> Artwork
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                artwork()
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 112)
            .padding(12)
            .background(isSelected ? Color.mint.opacity(0.14) : .white.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? Color.mint : .white.opacity(0.12), lineWidth: 1.5)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.mint)
                        .padding(10)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Select " + title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Applies immediately and closes face selection.")
    }

    @ViewBuilder
    private func thumbnail(_ avatar: AvatarDescriptor) -> some View {
        if let url = AvatarCatalog.resource(avatar.thumbnail),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            Image(systemName: "person.crop.square")
                .font(.system(size: 34, weight: .light))
                .frame(height: 64)
        }
    }
}
