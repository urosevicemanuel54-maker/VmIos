//
//  Theme.swift
//  Vortex
//
//  Palette for the instrument-panel look of the emulator screens.
//

import SwiftUI

enum VortexPalette {
    static let background = Color(red: 0.043, green: 0.051, blue: 0.075)
    static let surface = Color(red: 0.078, green: 0.090, blue: 0.114)
    static let surfaceRaised = Color(red: 0.106, green: 0.120, blue: 0.150)
    static let stroke = Color.white.opacity(0.08)
    static let primaryText = Color.white
    static let secondaryText = Color(white: 0.66)
    static let tertiaryText = Color(white: 0.42)
    static let accent = Color(red: 0.231, green: 0.427, blue: 0.969)
    static let positive = Color(red: 0.42, green: 0.85, blue: 0.53)
    static let warning = Color(red: 0.98, green: 0.72, blue: 0.30)
    static let serious = Color(red: 0.98, green: 0.52, blue: 0.28)
    static let critical = Color(red: 0.96, green: 0.32, blue: 0.32)
}
