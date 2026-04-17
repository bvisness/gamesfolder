package minesweeper

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "vendor:sdl3"

GAME_PADDING :: 20
FACE_BAR_HEIGHT :: 50

BUTTON_SIZE :: 36
BUTTON_PADDING :: 4
MAX_ROWS, MAX_COLS :: 20, 40

// This is just what SDL does I guess
MOUSE_LEFT :: 1
MOUSE_RIGHT :: 3
CLICK_RELEASE_RADIUS :: 20

// ----------------------------------------------------------------------------
// Game logic

// ----------------------------------------------------------------------------
// Textures

TextureDrawMode :: enum {
	NORMAL,
	NINESLICE,
	NINESLICE_TILED,
}

Texture :: struct {
	mode:        TextureDrawMode,
	src:         Maybe(sdl3.FRect),
	slices:      [4]f32, // left, right, top, bottom, relative to original img
	slice_scale: f32,

	// Filled in when loading
	tex:         ^sdl3.Texture,
	size:        [2]f32,
	full_rect:   sdl3.FRect,
}

texture_grid :: proc "contextless" (
	$N: int,
	template: Texture,
	start: [2]f32,
	size: [2]f32,
	offset: [2]f32,
	per_row: int,
) -> (
	res: [N]Texture,
) {
	for _, i in res {
		row := f32(i / per_row)
		col := f32(i % per_row)

		res[i] = template
		res[i].src = sdl3.FRect{start.x + col * offset.x, start.y + row * offset.y, size.x, size.y}
	}
	return
}

t_clubs := texture_grid(4, Texture{}, {850, 250}, {1230 - 1054, 642 - 449}, {200, 200}, 2)
t_spades := texture_grid(4, Texture{}, {1300, 250}, {150, 195}, {200, 250}, 2)
t_diamonds := texture_grid(4, Texture{}, {1750, 250}, {150, 200}, {150, 250}, 2)
t_hearts := texture_grid(4, Texture{}, {2150, 250}, {170, 170}, {200, 200}, 2)
t_numbers := texture_grid(26, Texture{}, {850, 750}, {145, 200}, {150, 250}, 13)

// ----------------------------------------------------------------------------
// Utilities

trapf :: proc(msg: string, args: ..any, location := #caller_location) {
	log.errorf(msg, ..args, location = location)
	intrinsics.debug_trap()
}

must :: proc(val: $T, msg: string, args: ..any, location := #caller_location) -> T {
	zero: T
	if val == zero {
		log.errorf(msg, ..args, location = location)
		intrinsics.debug_trap()
	}
	return val
}

must1 :: proc(val: $T, err: $E, msg: string, args: ..any, location := #caller_location) -> T {
	zero: E
	if err != zero {
		log.errorf(msg, ..args, location = location)
		log.errorf("Crashed with error: %v.", err, location = location)
		intrinsics.debug_trap()
	}
	return val
}

// ----------------------------------------------------------------------------
// Loading & initialization

CTX :: struct {
	window:           ^sdl3.Window,
	renderer:         ^sdl3.Renderer,
	should_close:     bool,

	// Size
	window_size:      [2]i32,

	// Timing
	t:                f64,
	dt:               f64,
	dirty:            bool,

	// Input
	mouse_pos:        sdl3.FPoint,
	mouse_down:       [10]bool,
	mouse_pressed:    [10]bool,
	mouse_released:   [10]bool,

	// UI state
	hot_item_buf:     [256]byte,
	hot_item:         string,
	hot_mouse_button: int,
}
ctx := CTX{}

init_sdl :: proc() -> (ok: bool) {
	if !sdl3.SetAppMetadata("Solitaire", "0.1", "me.bvisness.gamesfolder.solitaire") {
		log.errorf("sdl3.SetAppMetadata failed.")
		return
	}

	if sdl_res := sdl3.Init(sdl3.INIT_VIDEO); !sdl_res {
		log.errorf("sdl3.Init failed.")
		return false
	}

	if !sdl3.CreateWindowAndRenderer(
		"Solitaire",
		800,
		600,
		sdl3.WindowFlags{},
		&ctx.window,
		&ctx.renderer,
	) {
		log.errorf("sdl3.CreateWindowAndRenderer failed.")
		return false
	}

	load_texture_slice_from_png(
		"resources/solitaire.png",
		t_clubs[:],
		t_spades[:],
		t_diamonds[:],
		t_hearts[:],
		t_numbers[:],
	)

	return true
}

cleanup :: proc() {
	sdl3.DestroyWindow(ctx.window)
	sdl3.Quit()
}

load_textures_from_png :: proc(path: string, textures: ..^Texture) {
	fullpath := must1(
		filepath.join([]string{string(sdl3.GetBasePath()), path}, context.temp_allocator),
		"Failed to join path.",
	)
	res := must(
		strings.clone_to_cstring(fullpath, context.temp_allocator),
		"Failed to load image %s.",
		path,
	)

	surface := must(sdl3.LoadPNG(res), "Failed to load bitmap %s: %s.", path, sdl3.GetError())
	defer sdl3.DestroySurface(surface)

	sdl_tex := must(
		sdl3.CreateTextureFromSurface(ctx.renderer, surface),
		"Failed to create texture for %s: %s.",
		path,
		sdl3.GetError(),
	)

	for tex in textures {
		tex.tex = sdl_tex
		if src, ok := tex.src.?; ok {
			tex.size = {src.w, src.h}
		} else {
			tex.size = {f32(surface.w), f32(surface.h)}
		}
		tex.full_rect = sdl3.FRect{0, 0, f32(surface.w), f32(surface.h)}
	}
}

load_texture_slice_from_png :: proc(path: string, textures: ..[]Texture) {
	total_len := 0
	for texes in textures {
		total_len += len(texes)
	}
	ptrs := make([]^Texture, total_len, context.temp_allocator)
	i := 0
	for texes in textures {
		for _, j in texes {
			ptrs[i] = &texes[j]
			i += 1
		}
	}
	load_textures_from_png(path, ..ptrs)
}

// ----------------------------------------------------------------------------
// UI state

set_hot :: proc(id: string, hot_mouse_button: int) -> (hover: bool, active: bool) {
	if ctx.hot_item != "" {
		return false, false
	}

	copy_from_string(ctx.hot_item_buf[:], id)
	ctx.hot_item = string(ctx.hot_item_buf[:len(id)])
	ctx.hot_mouse_button = hot_mouse_button
	log.infof("NOW HOT: %s, btn %d", ctx.hot_item, ctx.hot_mouse_button)

	ctx.dirty = true
	return true, true
}

check_hotness :: proc(id: string, rect: sdl3.FRect) -> (hover: bool, active: bool, clicked: int) {
	// If the item is "hot", meaning currently under interaction
	if ctx.hot_item == id {
		release_rect := sdl3.FRect {
			rect.x - CLICK_RELEASE_RADIUS,
			rect.y - CLICK_RELEASE_RADIUS,
			rect.w + 2 * CLICK_RELEASE_RADIUS,
			rect.h + 2 * CLICK_RELEASE_RADIUS,
		}
		if sdl3.PointInRectFloat(ctx.mouse_pos, release_rect) {
			if ctx.mouse_released[ctx.hot_mouse_button] {
				ctx.dirty = true
				return false, false, ctx.hot_mouse_button
			} else {
				return true, true, 0
			}
		}
		return false, false, 0
	}

	// Otherwise, maybe just hover
	hovered := sdl3.PointInRectFloat(ctx.mouse_pos, rect)
	return hovered, false, 0
}

// ----------------------------------------------------------------------------
// Rendering

draw :: proc() {
	sdl3.SetRenderDrawColor(ctx.renderer, 255, 255, 255, 255)
	sdl3.RenderClear(ctx.renderer)

	SCALE :: 0.4
	render_texture_pos(&t_clubs[0], {10, 10}, SCALE)
	render_texture_pos(&t_clubs[1], {110, 10}, SCALE)
	render_texture_pos(&t_clubs[2], {210, 10}, SCALE)
	render_texture_pos(&t_clubs[3], {310, 10}, SCALE)
	render_texture_pos(&t_spades[0], {10, 110}, SCALE)
	render_texture_pos(&t_spades[1], {110, 110}, SCALE)
	render_texture_pos(&t_spades[2], {210, 110}, SCALE)
	render_texture_pos(&t_spades[3], {310, 110}, SCALE)
	render_texture_pos(&t_diamonds[0], {10, 210}, SCALE)
	render_texture_pos(&t_diamonds[1], {110, 210}, SCALE)
	render_texture_pos(&t_diamonds[2], {210, 210}, SCALE)
	render_texture_pos(&t_diamonds[3], {310, 210}, SCALE)
	render_texture_pos(&t_hearts[0], {10, 310}, SCALE)
	render_texture_pos(&t_hearts[1], {110, 310}, SCALE)
	render_texture_pos(&t_hearts[2], {210, 310}, SCALE)
	render_texture_pos(&t_hearts[3], {310, 310}, SCALE)

	for r in 0 ..= 1 {
		for n in 0 ..< 13 {
			render_texture_pos(&t_numbers[r * 13 + n], {10 + 40 * f32(n), 410 + 60 * f32(r)}, 0.2)
		}
	}

	sdl3.RenderPresent(ctx.renderer)
}

render_texture :: proc(texture: ^Texture, dst: sdl3.FRect) {
	assert(texture.tex != nil, "texture was not loaded!")
	src: Maybe(^sdl3.FRect)
	dst := dst
	if _, ok := texture.src.?; ok {
		src = &texture.src.?
	}
	scale := texture.slice_scale
	if scale == 0 {
		scale = 1
	}

	switch texture.mode {
	case .NORMAL:
		sdl3.RenderTexture(ctx.renderer, texture.tex, src, &dst)
	case .NINESLICE:
		sdl3.RenderTexture9Grid(
			ctx.renderer,
			texture.tex,
			src,
			texture.slices[0],
			texture.slices[1],
			texture.slices[2],
			texture.slices[3],
			scale,
			&dst,
		)
	case .NINESLICE_TILED:
		sdl3.RenderTexture9GridTiled(
			ctx.renderer,
			texture.tex,
			src,
			texture.slices[0],
			texture.slices[1],
			texture.slices[2],
			texture.slices[3],
			scale,
			&dst,
			scale,
		)
	case:
		trapf("bad render mode: %v", texture.mode)
	}
}

render_texture_pos :: proc(texture: ^Texture, pos: [2]f32, scale: f32) {
	render_texture(
		texture,
		sdl3.FRect{pos.x, pos.y, texture.size.x * scale, texture.size.y * scale},
	)
}

// ----------------------------------------------------------------------------
// Game loop

loop :: proc() {
	free_all(context.temp_allocator)

	loop_context := context
	ctx.t = f64(sdl3.GetTicksNS()) / 1_000_000_000
	ctx.dt = 0.001 // default to 1ms for the first frame

	// Some jank you have to do in order to continue drawing while resizing the
	// window. https://wiki.libsdl.org/SDL3/AppFreezeDuringDrag
	ok := sdl3.AddEventWatch(proc "c" (userdata: rawptr, event: ^sdl3.Event) -> bool {
			context = (^runtime.Context)(userdata)^
			if event.type == .WINDOW_EXPOSED {
				sdl3.GetWindowSize(ctx.window, &ctx.window_size.x, &ctx.window_size.y)
				frame(false)
			}
			return true
		}, &loop_context)
	if !ok {
		log.error("sdl3.AddEventWatch failed.")
		return
	}

	for !ctx.should_close {
		e: sdl3.Event
		if ctx.dirty {
			// Just do a frame right away (but only one)
			ctx.dirty = false
		} else {
			// Wait for events, then process them all
			if !sdl3.WaitEvent(&e) {
				panic("failed sdl3.WaitEvent")
			}
			process_event(&e)
		}
		for sdl3.PollEvent(&e) {
			process_event(&e)
		}

		frame(true)
	}
}

process_event :: proc(e: ^sdl3.Event) {
	#partial switch (e.type) {
	case .QUIT:
		ctx.should_close = true
	case .MOUSE_BUTTON_DOWN, .MOUSE_BUTTON_UP:
		ctx.mouse_pressed[e.button.button] = !ctx.mouse_down[e.button.button] && e.button.down
		ctx.mouse_released[e.button.button] = ctx.mouse_down[e.button.button] && !e.button.down
		ctx.mouse_down[e.button.button] = e.button.down
	case .MOUSE_MOTION:
		ctx.mouse_pos = {e.motion.x, e.motion.y}
	case .WINDOW_RESIZED:
		sdl3.GetWindowSize(ctx.window, &ctx.window_size.x, &ctx.window_size.y)
		log.infof("Window now has size: %v.", ctx.window_size)
	}
}

frame :: proc(do_input: bool) {
	draw()

	new_t := f64(sdl3.GetTicksNS()) / 1_000_000_000
	ctx.dt = new_t - ctx.t
	ctx.t = new_t

	// Clear out frame-ephemeral state
	if ctx.mouse_released[ctx.hot_mouse_button] {
		ctx.hot_item = ""
		ctx.hot_mouse_button = 0
	}
	for &pressed in ctx.mouse_pressed {
		pressed = false
	}
	for &released in ctx.mouse_released {
		released = false
	}
}

// ----------------------------------------------------------------------------
// Main

main :: proc() {
	context.logger = log.create_console_logger()

	if res := init_sdl(); !res {
		log.errorf("Initialization failed.")
		os.exit(1)
	}
	defer cleanup()

	loop()

	log.info("Done.")
}
