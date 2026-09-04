import QtQuick
import QtQuick.Particles
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

// Weather on the inside of the glass. One transparent, fully click-through
// layer-shell surface per screen, carrying three independent layers:
//
//   1. streaks — falling rain/snow, GPU particles (QtQuick.Particles)
//   2. beads   — droplets clinging to the glass that dwell, then run down
//                leaving a fading trail; a fixed pool that recycles itself
//   3. flash   — full-screen lightning, thunderstorm only
//
// Note we cannot refract what is behind the surface: a Wayland layer surface
// has no read access to the composited framebuffer beneath it. So the beads
// are painted light — rim, highlight and trail — rather than true distortion.
// It reads convincingly and costs nothing.
//
// When there is no weather the PanelWindow is left unmapped, so a dry day is
// genuinely free rather than a transparent fullscreen surface the compositor
// has to blend every frame.
Item {
  id: root

  property var shell: null
  property var manifest: null

  // --- live config, pushed from BarWidget.applyConfig ------------------
  property bool showWeather: true
  property string conditions: "Rain"        // Drizzle | Rain | Downpour | Thunderstorm | Snow
  property string stackLayer: "top"         // top | bottom | overlay
  property real densityScale: 1.0
  property bool wantStreaks: true
  property bool wantBeads: true
  property bool wantLightning: true
  property real windAngle: 0                // degrees off vertical
  property real windVariation: 1

  // Pause outright while something is fullscreen (a game, a video). The
  // surface is unmapped rather than hidden, so the effect costs nothing
  // at exactly the moment you least want it running.
  property bool pauseOnFullscreen: true
  property bool fullscreenActive: false

  readonly property bool isSnow: conditions === "Snow"
  readonly property bool isStorm: conditions === "Thunderstorm"
  // The surface only exists when there is something to draw.
  readonly property bool active: showWeather && (wantStreaks || wantBeads)
                                 && !(pauseOnFullscreen && fullscreenActive)

  function applyConfig(s) {
    if (!s) return
    if (typeof s.enabled === "boolean") showWeather = s.enabled
    if (typeof s.streaks === "boolean") wantStreaks = s.streaks
    if (typeof s.beads === "boolean") wantBeads = s.beads
    if (typeof s.lightning === "boolean") wantLightning = s.lightning
    if (typeof s.pauseFullscreen === "boolean") pauseOnFullscreen = s.pauseFullscreen
    if (typeof s.intensity === "string") conditions = s.intensity
    stackLayer = s.layer === "On the desktop" ? "bottom"
               : s.layer === "Above everything" ? "overlay" : "top"
    densityScale = s.density === "Sparse" ? 0.5 : s.density === "Heavy" ? 1.8 : 1.0
    // Keep the variation tight: real rain falls as a coherent sheet, and
    // per-streak angle scatter reads as mess rather than turbulence.
    if (s.wind === "Light")      { windAngle = 5;  windVariation = 2 }
    else if (s.wind === "Gusty") { windAngle = 16; windVariation = 6 }
    else                         { windAngle = 0;  windVariation = 1 }
  }

  // --- condition presets ------------------------------------------------
  // emitRate is per-screen and already density-scaled at the call site.
  readonly property var preset: ({
    "Drizzle":      { rate: 40,  life: 2600, speed: 620,  len: [7, 14],  thick: 1.0, alpha: 0.26, beads: 14, bead: [3, 7] },
    "Rain":         { rate: 120, life: 2000, speed: 1000, len: [13, 26], thick: 1.3, alpha: 0.34, beads: 26, bead: [4, 10] },
    "Downpour":     { rate: 300, life: 1500, speed: 1500, len: [20, 40], thick: 1.6, alpha: 0.42, beads: 44, bead: [5, 13] },
    "Thunderstorm": { rate: 330, life: 1400, speed: 1650, len: [24, 46], thick: 1.7, alpha: 0.46, beads: 50, bead: [5, 14] },
    "Snow":         { rate: 70, life: 9000, speed: 90,   len: [3, 7],   thick: 3.0, alpha: 0.72, beads: 0,  bead: [0, 0] }
  })
  readonly property var p: preset[conditions] || preset["Rain"]

  function rand(a, b) { return a + Math.random() * (b - a) }

  Socket {
    id: hyprEvents
    connected: root.showWeather && root.pauseOnFullscreen
    path: Quickshell.env("XDG_RUNTIME_DIR") + "/hypr/"
          + Quickshell.env("HYPRLAND_INSTANCE_SIGNATURE") + "/.socket2.sock"
    parser: SplitParser {
      onRead: function (line) {
        if (line.indexOf("fullscreen>>") === 0)
          root.fullscreenActive = line.substring(12).trim() === "1"
      }
    }
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: win
      required property var modelData
      screen: modelData
      // Unmapped entirely when there is no weather — costs nothing when dry.
      visible: root.active

      anchors { top: true; bottom: true; left: true; right: true }
      color: "transparent"
      exclusionMode: ExclusionMode.Ignore

      WlrLayershell.namespace: "bert-pane"
      WlrLayershell.layer: root.stackLayer === "overlay" ? WlrLayer.Overlay
                         : root.stackLayer === "bottom"  ? WlrLayer.Bottom
                         : WlrLayer.Top
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

      // Empty region: every click, drag and hover passes straight through.
      mask: Region {}

      // ---------------------------------------------------------------
      // 1. Falling rain / snow
      // ---------------------------------------------------------------
      ParticleSystem {
        id: sys
        running: root.active && root.wantStreaks
        paused: !win.visible
      }

      Emitter {
        system: sys
        enabled: root.active && root.wantStreaks
        // Emit from a band above the top edge so streaks are already at
        // full speed by the time they cross into view.
        width: win.width * 1.4
        height: 10
        x: -win.width * 0.2
        y: -30
        emitRate: Math.round(root.p.rate * root.densityScale)
        lifeSpan: root.p.life
        lifeSpanVariation: Math.round(root.p.life * 0.25)
        size: root.isSnow ? 7 : (root.p.len[0] + root.p.len[1]) / 2
        sizeVariation: root.isSnow ? 5 : (root.p.len[1] - root.p.len[0]) / 2
        velocity: AngleDirection {
          // 90 deg is straight down in particle space; wind tilts it.
          angle: 90 - root.windAngle
          angleVariation: root.windVariation
          magnitude: root.p.speed
          magnitudeVariation: root.p.speed * 0.22
        }
        acceleration: AngleDirection {
          angle: 90
          magnitude: root.isSnow ? 6 : 240      // snow drifts, rain accelerates
        }
      }

      // Snow wanders sideways; rain does not.
      Wander {
        system: sys
        enabled: root.isSnow && root.active && root.wantStreaks
        xVariance: 42
        pace: 22
      }

      // ImageParticle, not ItemParticle: this is a batched GPU quad per
      // particle rather than a live QML item. At Thunderstorm/Heavy there are
      // ~1700 particles alive at once, and instantiating that many items cost
      // ~80% of a core. The elongation of a streak lives inside the sprite,
      // since ImageParticle always draws into a square size x size quad.
      ImageParticle {
        system: sys
        source: root.isSnow ? Qt.resolvedUrl("assets/flake.png")
                            : Qt.resolvedUrl("assets/streak.png")
        color: Qt.rgba(0.86, 0.93, 1.0, root.p.alpha)
        colorVariation: 0.05
        alphaVariation: root.p.alpha * 0.45
        // Rain leans into its own travel; flakes stay upright.
        autoRotation: !root.isSnow
      }

      // ---------------------------------------------------------------
      // 2. Beads on the glass
      //
      // A fixed pool that recycles: each bead picks a spot, fades in,
      // clings for a while, then accelerates down the screen trailing a
      // fading streak, then respawns somewhere new. No model churn, so
      // the item count is constant and the scene graph stays batched.
      // ---------------------------------------------------------------
      Repeater {
        model: root.wantBeads && !root.isSnow
               ? Math.round(root.p.beads * root.densityScale) : 0

        delegate: Item {
          id: bead

          property real bsize: 6
          property real startY: 0
          property real travel: 0        // px fallen so far — drives the trail

          width: bsize
          height: bsize * 1.3
          y: startY + travel
          opacity: 0

          function respawn() {
            cycle.stop()
            bsize  = root.rand(root.p.bead[0], root.p.bead[1])
            x      = root.rand(0, Math.max(1, win.width - bsize))
            startY = root.rand(-20, win.height * 0.8)
            travel = 0
            // Bigger beads are heavier: they cling less and fall faster.
            var heaviness = (bsize - root.p.bead[0]) / Math.max(1, root.p.bead[1] - root.p.bead[0])
            dwell.duration = Math.round(root.rand(600, 9000) * (1.25 - heaviness))
            var dist = win.height + 40 - startY
            fall.to = dist
            fall.duration = Math.round(dist / (150 + heaviness * 620) * 1000)
            cycle.start()
          }

          Component.onCompleted: {
            // Stagger the pool so they do not all arrive on the same beat.
            stagger.interval = Math.round(Math.random() * 6000)
            stagger.start()
          }
          Timer { id: stagger; repeat: false; onTriggered: bead.respawn() }

          SequentialAnimation {
            id: cycle
            NumberAnimation { target: bead; property: "opacity"; to: 1; duration: 420 }
            PauseAnimation  { id: dwell; duration: 2000 }
            NumberAnimation {
              id: fall
              target: bead; property: "travel"; to: 500
              duration: 1400; easing.type: Easing.InQuad     // accelerates as it runs
            }
            NumberAnimation { target: bead; property: "opacity"; to: 0; duration: 200 }
            ScriptAction { script: bead.respawn() }
          }

          // Trail left on the glass above the bead, brightest just behind it.
          Rectangle {
            width: Math.max(1, bead.bsize * 0.42)
            height: Math.min(bead.travel, 150)
            anchors.horizontalCenter: parent.horizontalCenter
            y: -height
            visible: height > 1
            gradient: Gradient {
              GradientStop { position: 0.0; color: Qt.rgba(0.85, 0.93, 1.0, 0.0) }
              GradientStop { position: 1.0; color: Qt.rgba(0.85, 0.93, 1.0, 0.15) }
            }
          }

          // The bead body: dark rim up top, bright pool at the bottom, which
          // is what sells "water on glass" without any real refraction.
          Rectangle {
            anchors.fill: parent
            radius: width / 2
            antialiasing: true
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.30)
            gradient: Gradient {
              GradientStop { position: 0.0; color: Qt.rgba(0.55, 0.65, 0.78, 0.16) }
              GradientStop { position: 0.7; color: Qt.rgba(0.88, 0.95, 1.00, 0.30) }
              GradientStop { position: 1.0; color: Qt.rgba(1.00, 1.00, 1.00, 0.46) }
            }
          }

          // Specular pin-prick, up and to the left, like a light source.
          Rectangle {
            width: Math.max(1, bead.bsize * 0.26)
            height: width
            radius: width / 2
            antialiasing: true
            x: bead.bsize * 0.24
            y: bead.bsize * 0.22
            color: Qt.rgba(1, 1, 1, 0.75)
          }
        }
      }

      // ---------------------------------------------------------------
      // 3. Lightning
      // ---------------------------------------------------------------
      Rectangle {
        anchors.fill: parent
        color: "white"
        opacity: 0
        visible: opacity > 0

        SequentialAnimation {
          id: flash
          // Double-strike: sharp leader, gap, weaker return stroke.
          NumberAnimation { target: parent; property: "opacity"; to: 0.50; duration: 45 }
          NumberAnimation { target: parent; property: "opacity"; to: 0.05; duration: 90 }
          NumberAnimation { target: parent; property: "opacity"; to: 0.30; duration: 60 }
          NumberAnimation { target: parent; property: "opacity"; to: 0.0;  duration: 420 }
        }

        Timer {
          running: root.active && root.isStorm && root.wantLightning
          repeat: true
          interval: 6000
          onTriggered: {
            if (Math.random() < 0.45) flash.restart()
            interval = Math.round(root.rand(4000, 17000))
          }
        }
      }
    }
  }
}
