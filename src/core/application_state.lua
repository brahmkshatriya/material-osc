local application_state = {}

local TOOLTIP_FADE_DURATION = 0.14
local TOOLTIP_SPRING_STIFFNESS = 420
local TOOLTIP_SPRING_DAMPING = 20

function application_state.new(args)
  local opts = args.opts
  local animation = args.animation
  local runtime = {
    viewport = {w = 1280, h = 720, dpi = 1},
    controller = {
      visible = opts.always_visible,
      bounds = nil
    },
    pointer = {x = -1, y = -1, active = nil},
    input = {hitboxes = {}, order = {}, next_id = 0},
    time = {show_remaining = false},
    seek = {dragging = false, position = nil, offset_x = 0},
    chapter = {
      open = false, scroll_index = 0, bounds = nil,
      dragging_scroll = false, hidden_notified = true
    },
    playlist = {
      open = false, scroll_index = 0, bounds = nil, list_bounds = nil,
      anchor_bounds = nil,
      drag_from = nil, drag_to = nil, drag_start_y = nil,
      dragging_scroll = false,
      shuffled = false, shuffle_initialized = false,
      hidden_notified = true
    },
    subtitle = {open = false, scroll_index = 0, bounds = nil, hidden_notified = true},
    audio = {open = false, scroll_index = 0, bounds = nil, hidden_notified = true},
    settings = {
      open = false, page = "root", pending_page = nil,
      transition_phase = nil, resize_started = false,
      scroll_index = 0, bounds = nil, hidden_notified = true
    },
    volume = {
      dragging = false, popup_bounds = nil, button_bounds = nil,
      tooltip_suppressed_until = 0
    },
    playback_indicator = {
      last_paused = nil, last_volume = nil, last_muted = nil,
      icon = "play_arrow", label = nil, label_color = "#FFFFFF",
      hide_timer = nil
    },
    ytdl = {
      active = false, source = nil, url = nil, items = {}, caption_items = {},
      request_id = 0, selected_id = nil, pending_selected_id = nil,
      pending_playback_url = nil,
      caption_loading_id = nil, caption_request_id = 0,
      pending_subtitles = nil
    },
    tooltip = {hover_key = nil, hover_start = 0, requested = false, visual = nil},
    thumbnail = {
      preview = {width = 240, height = 135, disabled = false, available = true},
      visible = false, request_pos = nil, loading = false, request_id = 0,
      request_timer = nil, exact_timer = nil, prewarm_timer = nil,
      overlay_id = 43, file = nil, file_width = 0, file_height = 0,
      target_x = nil, target_y = nil, display_x = nil, display_y = nil,
      pending_pos = nil, last_seek_at = -math.huge, worker_id = nil,
      worker_socket = nil, worker_command_file = nil,
      worker_command_handle = nil, worker_client_script = nil,
      worker_output = nil, worker_candidate = nil, worker_display = nil,
      worker_width = 0, worker_height = 0, worker_source = nil,
      poll_timer = nil
    },
    timers = {hide = nil, frame = nil, frame_interval = 1 / 60},
    loading = {started_ms = args.now_ms(), quality_switching = false},
    media = {loading = true},
    effects = {order = {}, by_key = {}},
    snapshot = {},
    frame = {rendering = false, pending = false}
  }

  runtime.controller.opacity = animation.tween({
    initial = opts.always_visible and 1 or 0, duration = 0.18
  })
  runtime.volume.animation = animation.spring({initial = 0, stiffness = 360, damping = 24})
  runtime.chapter.animation = animation.spring({initial = 0, stiffness = 380, damping = 26})
  runtime.playlist.animation = animation.spring({initial = 0, stiffness = 380, damping = 26})
  runtime.playlist.width_animation = animation.spring({
    initial = 118, stiffness = 560, damping = 38
  })
  runtime.playlist.height_animation = animation.spring({
    initial = 42, stiffness = 560, damping = 38
  })
  runtime.subtitle.animation = animation.spring({initial = 0, stiffness = 380, damping = 26})
  runtime.audio.animation = animation.spring({initial = 0, stiffness = 380, damping = 26})
  runtime.settings.animation = animation.spring({initial = 0, stiffness = 380, damping = 26})
  runtime.settings.content_animation = animation.tween({initial = 1, duration = 0.12})
  runtime.settings.width_animation = animation.spring({initial = 320, stiffness = 560, damping = 38})
  runtime.settings.height_animation = animation.spring({initial = 292, stiffness = 560, damping = 38})
  runtime.playback_indicator.opacity = animation.tween({initial = 0, duration = 0.18})
  runtime.playback_indicator.scale = animation.spring({initial = 1, stiffness = 520, damping = 32})
  runtime.tooltip.opacity = animation.tween({initial = 0, duration = TOOLTIP_FADE_DURATION})
  runtime.tooltip.slide = animation.spring({
    initial = 0,
    stiffness = TOOLTIP_SPRING_STIFFNESS,
    damping = TOOLTIP_SPRING_DAMPING
  })

  return runtime
end

return application_state
