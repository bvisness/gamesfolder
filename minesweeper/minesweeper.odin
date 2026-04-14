package minesweeper

import "base:intrinsics"
import "base:runtime"
import "core:log"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "vendor:sdl3"

sanic: ^sdl3.Texture

CTX :: struct {
	window:       ^sdl3.Window,
	renderer:     ^sdl3.Renderer,
	should_close: bool,

	// Timing
	t:            f64,
	dt:           f64,
}

ctx := CTX{}

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

init_sdl :: proc() -> (ok: bool) {
	if !sdl3.SetAppMetadata("Minesweeper", "0.1", "me.bvisness.gamesfolder.minesweeper") {
		log.errorf("sdl3.SetAppMetadata failed.")
		return
	}

	if sdl_res := sdl3.Init(sdl3.INIT_VIDEO); !sdl_res {
		log.errorf("sdl3.Init failed.")
		return false
	}

	if !sdl3.CreateWindowAndRenderer(
		"Minesweeper",
		400,
		400,
		sdl3.WindowFlags{.RESIZABLE},
		&ctx.window,
		&ctx.renderer,
	) {
		log.errorf("sdl3.CreateWindowAndRenderer failed.")
		return false
	}

	sanic = load_texture_from_png("resources/gottagofast.png")

	return true
}

load_texture_from_png :: proc(path: string) -> ^sdl3.Texture {
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

	texture := must(
		sdl3.CreateTextureFromSurface(ctx.renderer, surface),
		"Failed to create texture for %s: %s.",
		path,
		sdl3.GetError(),
	)

	return texture
}

draw :: proc() {
	sdl3.SetRenderDrawColor(ctx.renderer, 0, 0, 0, 255)
	sdl3.RenderClear(ctx.renderer)

	w: f32 = 200 + f32(math.sin(ctx.t)) * 100
	h: f32 = 200 + f32(math.sin(ctx.t)) * 100
	rect := sdl3.FRect {
		x = 100,
		y = 100,
		w = w,
		h = h,
	}
	sdl3.RenderTexture(ctx.renderer, sanic, nil, &rect)

	sdl3.RenderPresent(ctx.renderer)
}

cleanup :: proc() {
	sdl3.DestroyWindow(ctx.window)
	sdl3.Quit()
}

process_event :: proc(e: ^sdl3.Event) {
	#partial switch (e.type) {
	case .QUIT:
		ctx.should_close = true
	}
}

frame :: proc(do_input: bool) {
	draw()

	new_t := f64(sdl3.GetTicksNS()) / 1_000_000_000
	ctx.dt = new_t - ctx.t
	ctx.t = new_t
}

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
				frame(false)
			}
			return true
		}, &loop_context)
	if !ok {
		log.error("sdl3.AddEventWatch failed.")
		return
	}

	for !ctx.should_close {
		// Wait for events, then process them all
		e: sdl3.Event
		if !sdl3.WaitEvent(&e) {
			panic("failed sdl3.WaitEvent")
		}
		process_event(&e)
		for sdl3.PollEvent(&e) {
			process_event(&e)
		}

		frame(true)
	}
}

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
