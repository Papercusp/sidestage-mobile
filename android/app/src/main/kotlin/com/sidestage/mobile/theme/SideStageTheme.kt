// SPDX-License-Identifier: MIT
@file:Suppress("ktlint:standard:function-naming")

package com.sidestage.mobile.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

private val SideStageColorScheme =
    lightColorScheme(
        primary = SideStageTokens.Accent,
        onPrimary = SideStageTokens.OnAccent,
        primaryContainer = SideStageTokens.AccentWash,
        onPrimaryContainer = SideStageTokens.Ink,
        secondary = SideStageTokens.Success,
        onSecondary = SideStageTokens.OnAccent,
        secondaryContainer = SideStageTokens.SuccessWash,
        onSecondaryContainer = SideStageTokens.Ink,
        background = SideStageTokens.Background,
        onBackground = SideStageTokens.Ink,
        surface = SideStageTokens.Surface,
        onSurface = SideStageTokens.Ink,
        surfaceVariant = SideStageTokens.BackgroundWash,
        onSurfaceVariant = SideStageTokens.Muted,
        outline = SideStageTokens.Border,
    )

private val SideStageTypography =
    Typography(
        headlineMedium =
            TextStyle(
                fontFamily = FontFamily.Default,
                fontWeight = FontWeight.Bold,
                fontSize = 28.sp,
                lineHeight = 34.sp,
                letterSpacing = (-0.4).sp,
            ),
        titleLarge =
            TextStyle(
                fontFamily = FontFamily.Default,
                fontWeight = FontWeight.Bold,
                fontSize = 20.sp,
                lineHeight = 26.sp,
            ),
        bodyMedium =
            TextStyle(
                fontFamily = FontFamily.Default,
                fontWeight = FontWeight.Normal,
                fontSize = 14.sp,
                // D3: one extra Android line-height step on dense mobile rows.
                lineHeight = 22.sp,
            ),
        labelMedium =
            TextStyle(
                fontFamily = FontFamily.Default,
                fontWeight = FontWeight.Medium,
                fontSize = 12.sp,
                lineHeight = 18.sp,
            ),
        labelLarge =
            TextStyle(
                fontFamily = FontFamily.Default,
                fontWeight = FontWeight.SemiBold,
                fontSize = 13.sp,
                lineHeight = 19.sp,
            ),
    )

@Composable
fun SideStageTheme(content: @Composable () -> Unit) {
    MaterialTheme(
        colorScheme = SideStageColorScheme,
        typography = SideStageTypography,
        content = content,
    )
}
