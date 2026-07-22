//
//  DeviceCardBackground.swift
//  Replicould — Devices feature
//
//  The raised, hairline-bordered card surface the inspector's roster sections
//  (attached / stowed / cargo) share — one definition instead of the three
//  identical private copies the Stage 1 file split carried over.
//

import SwiftUI
import UI

extension View {
    /// Wrap the view in the inspector's standard card surface.
    func deviceCardBackground() -> some View {
        background(
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(.rcSurfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                        .strokeBorder(.rcSeparator, lineWidth: Hairline.thin)
                )
        )
    }
}
