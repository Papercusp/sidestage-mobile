// SPDX-License-Identifier: MIT
package com.sidestage.mobile.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

// Android compile-time projection of the approved SideStage mobile design
// tokens (sidestage Android plan D-013). The source values match the canonical
// Buyer + Orders mockup: ivory, ink, vermilion, border, and muted text.
object SideStageTokens {
    val Background = Color(0xFFFFF8EF)
    val BackgroundWash = Color(0xFFFFF3E2)
    val Surface = Color(0xFFFFFDF8)
    val Ink = Color(0xFF2A1F1A)
    val Accent = Color(0xFFD62B1F)
    val AccentWash = Color(0xFFF6DCD8)
    val OnAccent = Color(0xFFFFFFFF)
    val Border = Color(0xFFEBDFCC)
    val Muted = Color(0xFF77685A)
    val Success = Color(0xFF1B7A4B)
    val SuccessWash = Color(0xFFE7F3EA)
    val Stage = Color(0xFF231C18)
    val StageInk = Color(0xFFEFE4D6)

    val MinimumTouchTarget = 44.dp
    val PrimaryButtonRadius = 20.dp
    val BottomGestureInset = 16.dp
}
