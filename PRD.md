# PRD: Ghost Mentor - Stealth Coding Assistant

## Overview

A macOS background service that provides invisible, on-demand coding mentorship. The application runs as a pure background process with no dock icon, menu bar presence, or visible footprint during screen sharing. It surfaces only when summoned via hotkey, presenting a floating overlay that guides users through coding problems with the authentic thinking process of a senior engineer.

---

## Problem Statement

Technical interviews and coding challenges require not just solutions, but demonstrable problem-solving methodology. Current tools either:
- Are visible and detectable (IDE extensions, browser tabs)
- Provide answers without teaching the reasoning
- Lack real-time context awareness (audio + visual)

Ghost Mentor solves this by being an invisible teacher that captures context (audio transcription + screenshots) and walks through problems exactly how a senior SWE/ML/DL engineer thinks out loud.

---

## Core Requirements

### 1. Stealth Architecture

| Requirement | Implementation |
|-------------|----------------|
| No Dock Icon | `LSUIElement = true` in Info.plist |
| No Menu Bar | Pure background agent (NSApplication.ActivationPolicy.accessory) |
| Screen Share Invisible | Window level below screen capture, `sharingType = .none` |
| Process Hidden | Launch as LaunchAgent, minimal process footprint |
| Summoning | Global hotkey brings overlay into view |

### 2. Session Flow

```
[Idle] ---(Start Session hotkey)---> [Listening]
                                          |
                    (captures audio transcription + screenshots)
                                          |
                                     [Processing]
                                          |
                    (AI generates structured response)
                                          |
                                     [Displaying]
                                          |
               (user navigates sections, iterates)
                                          |
            ---(Reset Session)---> [Idle]
```

### 3. UI Sections

The overlay displays a structured breakdown with six navigable sections:

| Section | Purpose | Content Style |
|---------|---------|---------------|
| **Problem** | Restate the problem in own words | "So what we're really being asked here is..." |
| **Clarifying Questions** | Questions to ask interviewer | "Before I dive in, I'd want to clarify..." |
| **Approach** | High-level strategy walkthrough | "My instinct is to reach for X because..." |
| **Tests** | Test cases and edge cases | "Let me think about what could break this..." |
| **Code** | Implementation with inline reasoning | Code blocks with natural comments |
| **Complexity** | Time/Space analysis | "Walking through this - each operation costs..." |

**Voice**: All content written as natural speech - first person, thinking out loud, with hesitations and course-corrections that mirror real reasoning.

### 4. Hotkey System

Fully configurable global hotkeys:

| Action | Default Binding | Behavior |
|--------|-----------------|----------|
| Toggle Visibility | `Cmd + Shift + G` | Show/hide overlay instantly |
| Start Session | `Cmd + Shift + S` | Begin audio capture, clear context |
| Screenshot | `Cmd + Shift + X` | Capture screen region, stack in context |
| Solve | `Cmd + Shift + Return` | Send context to AI, generate response |
| Reset Session | `Cmd + Shift + R` | Clear all context and responses |
| Next Section | `Cmd + ]` | Navigate to next section |
| Prev Section | `Cmd + [` | Navigate to previous section |
| Jump to Section | `Cmd + 1-6` | Direct jump (1=Problem, 6=Complexity) |
| Open Settings | `Cmd + Shift + ,` | Open settings panel |
| Quit | `Cmd + Shift + Q` | Quit Ghost Mentor |

### 5. Context Capture

#### Audio Transcription
- Microphone activation on "Start Session"
- Real-time transcription using macOS Speech Recognition
- Continuous capture until session reset
- Transcription displayed in collapsible context panel

#### Screenshot Stack
- Region selection tool (crosshair selector)
- Screenshots stored in session stack (LIFO display)
- Thumbnails visible in context panel
- Each screenshot sent as base64 to vision-capable models

### 6. AI Integration

Dual-provider support with seamless switching:

```swift
protocol AIProvider {
    func complete(context: SessionContext) async throws -> MentorResponse
}

class ClaudeProvider: AIProvider { ... }
class OpenAIProvider: AIProvider { ... }
```

**Configuration:**
- API keys stored in Keychain
- Provider toggle in settings overlay
- Model selection (Claude Opus/Sonnet, GPT-4o/GPT-4)
- Temperature and max tokens configurable

**Prompt Engineering:**
System prompt instructs model to:
- Respond as senior engineer thinking out loud
- Use first person, natural cadence
- Show reasoning, not just answers
- Acknowledge uncertainty where appropriate
- Structure response into the six sections

---

## Quick Start

### Build & Run

```bash
# Option 1: Using xcodegen (recommended)
brew install xcodegen
cd GhostMentor
xcodegen generate
open GhostMentor.xcodeproj

# Option 2: Build script
chmod +x build.sh
./build.sh

# Option 3: Direct Swift build
swift build -c release
```

### First Launch

1. **Grant Permissions**: On first run, macOS will prompt for:
   - Accessibility (for global hotkeys)
   - Microphone (for audio transcription)
   - Screen Recording (for screenshots)

2. **Configure API Keys**: Press `Cmd+Shift+,` to open settings and enter your API keys

3. **Start Using**:
   - `Cmd+Shift+G` to show/hide overlay
   - `Cmd+Shift+S` to start a session
   - `Cmd+Shift+X` to capture screenshots
   - `Cmd+Shift+Return` to solve

### Quitting

- Press `Cmd+Shift+Q` to quit
- Or from Settings panel, click "Quit Ghost Mentor"
- Or from terminal: `pkill GhostMentor`

---

## File Structure

```
GhostMentor/
├── App/
│   ├── GhostMentorApp.swift       # Entry point, activation policy
│   └── AppDelegate.swift          # Lifecycle, hotkey setup
├── Services/
│   ├── HotkeyManager.swift        # Global hotkey registration
│   ├── AudioCaptureService.swift  # Mic capture + transcription
│   ├── ScreenshotService.swift    # Region capture, stack mgmt
│   └── SessionController.swift    # State machine, orchestration
├── AI/
│   ├── AIProvider.swift           # Protocol definition
│   ├── ClaudeProvider.swift       # Claude API implementation
│   ├── OpenAIProvider.swift       # OpenAI API implementation
│   └── PromptBuilder.swift        # System prompt construction
├── Models/
│   ├── Session.swift              # Session state model
│   ├── MentorResponse.swift       # Parsed AI response sections
│   └── Screenshot.swift           # Image + metadata
├── Views/
│   ├── OverlayWindow.swift        # NSPanel configuration
│   ├── MentorView.swift           # Main SwiftUI view
│   ├── ContextSidebar.swift       # Transcript + screenshot stack
│   └── SettingsView.swift         # Configuration panel
├── Utilities/
│   ├── KeychainManager.swift      # Secure credential storage
│   └── SettingsManager.swift      # App settings persistence
├── Info.plist                     # LSUIElement = true
├── GhostMentor.entitlements       # Required permissions
├── project.yml                    # xcodegen config
└── build.sh                       # Build script
```

---

## Privacy & Security

- All data stays local (no external logging)
- API keys stored in macOS Keychain
- Audio never persisted to disk (in-memory only)
- Screenshots cleared on session reset
- No analytics, telemetry, or network calls except to AI providers

---

## Success Criteria

1. **Invisible**: Zero footprint in dock, menu bar, app switcher, screen share
2. **Responsive**: Overlay appears within 100ms of hotkey
3. **Contextual**: AI responses incorporate audio + screenshot context accurately
4. **Natural**: Responses read like a senior engineer thinking out loud
5. **Reliable**: Stable across multi-hour sessions
