#=
gridanim.jl -- the moving picture.

gridviz.jl draws the answer. This file draws the answer HAPPENING.

THE IDEA
--------
A DC-OPF solution is usually shown as arrows and numbers, which is a diagram of
a river drawn as a table of velocities. But the model's own geometry is already
a moving thing, and it has two layers:

  LAYER 1 -- THE TERRAIN.  Every bus carries a voltage phase angle, theta. Think
    of it as ground elevation. Power does not choose a route; it runs downhill,
    and the amount running down any line is (pipe diameter) x (height drop). So
    the background of every frame is the theta landscape itself, interpolated
    across the plane by inverse-distance weighting. Valleys are where load sits.
    Ridges are where generation sits. Redispatch is the ground being re-sculpted.

  LAYER 2 -- THE CARRIERS.  On top of the terrain, charge is drawn as discrete
    particles advected along each line. Their SPACING encodes |flow| (more power
    = denser stream) and their SPEED encodes |flow|/rateA (a line near its
    thermal limit runs visibly hot and fast). Direction is the true direction of
    the solved flow, so reversals are visible as the stream turning around.

Nothing here is decorative noise: every pixel is a number the solver produced.

DEPENDENCIES: Plots, DataFrames, Printf (all already in Project.toml)
=#

using Plots, DataFrames, Printf, Random

# --- the palette -----------------------------------------------------------
# Dark ground so that flowing charge can actually glow. Cool colours are low
# terrain, warm colours are congestion.
const BG        = RGB(0.043, 0.047, 0.055)
const TERRAIN   = cgrad([RGB(0.055,0.063,0.086), RGB(0.086,0.106,0.165),
                         RGB(0.114,0.161,0.235), RGB(0.161,0.216,0.298)])
const C_COOL    = RGB(0.35, 0.72, 0.85)
const C_WARM    = RGB(0.98, 0.72, 0.25)
const C_HOT     = RGB(0.95, 0.28, 0.22)
const C_GEN     = RGB(0.42, 0.87, 0.55)
const C_LOAD    = RGB(0.98, 0.45, 0.42)
const C_JUNC    = RGB(0.55, 0.58, 0.65)
const C_TEXT    = RGB(0.85, 0.86, 0.88)
const C_DIM     = RGB(0.65, 0.67, 0.72)

"""
    save_gif(anim, path; fps, dither)

Encode an animation to GIF with a single global palette and dithering OFF.

Why bother: a GIF holds 256 colours. The default encoder builds its palette per
run and then DITHERS to fake the missing ones, which turns the smooth phase-angle
terrain into crawling television static -- the gradient is subtle enough that
almost every pixel gets a different error-diffusion nudge each frame. Generating
one palette across all frames (`stats_mode=full`) and applying it with
`dither=none` gives clean flat bands that hold still.

Falls back to Plots' built-in encoder if no ffmpeg binary is on PATH.
"""
function save_gif(anim, path; fps = 14, dither = "none")
    ff = Sys.which("ffmpeg")
    if ff === nothing
        @warn "ffmpeg not found; falling back to the default encoder (expect dithering)"
        gif(anim, path; fps = fps)
        return path
    end
    tmp = mktempdir()
    try
        for (i, f) in enumerate(anim.frames)
            cp(joinpath(anim.dir, f), joinpath(tmp, @sprintf("f%05d.png", i)); force = true)
        end
        seq = joinpath(tmp, "f%05d.png")
        pal = joinpath(tmp, "palette.png")
        run(`$ff -y -v error -i $seq -vf palettegen=max_colors=256:stats_mode=full $pal`)
        run(`$ff -y -v error -framerate $fps -i $seq -i $pal
             -lavfi paletteuse=dither=$dither -loop 0 $path`)
    finally
        rm(tmp; recursive = true, force = true)
    end
    @info "Saved animation to $path"
    return path
end

"""Line colour as a function of how full the pipe is (0 -> 1)."""
function heat(u; cool = C_COOL, warm = C_WARM, hot = C_HOT)
    u = clamp(u, 0.0, 1.0)
    a, b, t = u < 0.55 ? (cool, warm, u / 0.55) : (warm, hot, (u - 0.55) / 0.45)
    RGB(red(a) + (red(b) - red(a)) * t,
        green(a) + (green(b) - green(a)) * t,
        blue(a) + (blue(b) - blue(a)) * t)
end

"""
    theta_field(coords, ids, theta, xlim, ylim; res, power)

Interpolate the bus phase angles into a continuous surface by inverse-distance
weighting -- the elevation map the power is running down. `power` controls how
sharply each bus dominates its own neighbourhood.
"""
function theta_field(coords, ids, theta::Dict, xlim, ylim; res = 110, power = 2.2)
    xs = range(xlim[1], xlim[2]; length = res)
    ys = range(ylim[1], ylim[2]; length = res)
    Z = Array{Float64}(undef, res, res)
    pts = [(coords[i][1], coords[i][2], theta[i]) for i in ids]
    @inbounds for (jy, y) in enumerate(ys), (jx, x) in enumerate(xs)
        num = 0.0; den = 0.0
        for (px, py, pv) in pts
            d2 = (x - px)^2 + (y - py)^2
            w = 1.0 / (d2^(power / 2) + 1e-6)
            num += w * pv; den += w
        end
        Z[jy, jx] = num / den
    end
    return xs, ys, Z
end

"""
    grid_frame(bus, branch, generation, flows, angles, coords; phase, ...)

Render ONE frame of the animation. `phase` in [0,1) advances the carriers.

Keywords
  hud          : vector of (label, value) strings drawn in the top-left readout
  title        : headline text
  unlimited    : rateA at or above this is treated as "no thermal limit"
  density      : carriers per unit of normalised flow
  show_terrain : draw the theta elevation map behind the network
"""
function grid_frame(bus, branch, generation, flows, angles, coords;
                    phase = 0.0, hud = Tuple{String,String}[], title = "",
                    unlimited = 9000.0, density = 26.0, show_terrain = true,
                    maxflow_ref = nothing, size = nothing,
                    seed = 0, bands = 16, jitter = 0.0,
                    cool = C_COOL, warm = C_WARM, hot = C_HOT, ground = TERRAIN)

    # Seeded variation. The optimisation fixes every quantity that matters;
    # the seed moves only what it leaves undetermined -- where along a
    # conductor each carrier stream starts, and how far each carrier sits off
    # the centre line. Same seed, same texture, always.
    rng = MersenneTwister(seed)
    stream_offset = rand(rng, nrow(branch))
    carrier_jit = rand(rng, nrow(branch), 96) .* 2 .- 1

    ids = collect(bus.bus_i)
    xs0 = [coords[i][1] for i in ids]; ys0 = [coords[i][2] for i in ids]
    xr = maximum(xs0) - minimum(xs0); yr = maximum(ys0) - minimum(ys0)
    span = max(xr, yr, 1e-6); pad = 0.14 * span
    # The readout gets its OWN band of sky above the network. Without this the
    # text lands on whatever bus happens to sit near the top of the layout.
    rows = length(hud) + (isempty(title) ? 0 : 1)
    band = rows == 0 ? 0.0 : (0.055 * rows + 0.06) * span
    xlim = (minimum(xs0) - pad, maximum(xs0) + pad)
    ylim = (minimum(ys0) - pad, maximum(ys0) + pad + band)

    if size === nothing
        w = xlim[2] - xlim[1]; h = ylim[2] - ylim[1]
        base = 980
        size = w >= h ? (base, round(Int, base * h / w)) :
                        (round(Int, base * w / h), base)
    end

    p = plot(; size = size, legend = false, framestyle = :none,
             aspect_ratio = :equal, background_color = BG,
             xlims = xlim, ylims = ylim, grid = false,
             foreground_color = C_TEXT, margin = 0Plots.mm)

    # ---- LAYER 1: the elevation map -------------------------------------
    # Drawn as filled CONTOUR BANDS rather than a heatmap. Two reasons: a
    # heatmap gets resampled onto the equal-aspect axes and the resampling
    # sprays visible noise across what should be a smooth gradient; and
    # contours are what an elevation map actually looks like, so the faint
    # isolines double as equipotential lines of the phase angle.
    if show_terrain
        th = Dict(r.bus => r.theta for r in eachrow(angles))
        fx, fy, Z = theta_field(coords, ids, th, xlim, ylim)
        if maximum(Z) - minimum(Z) > 1e-9
            contourf!(p, fx, fy, Z; levels = bands, c = ground,
                      linewidth = 0, colorbar = false)
            contour!(p, fx, fy, Z; levels = bands, color = RGB(0.30, 0.40, 0.55),
                     linewidth = 0.5, alpha = 0.30, colorbar = false)
        end
    end

    maxflow = maxflow_ref === nothing ?
              max(maximum(abs.(flows.flow); init = 1.0), 1e-6) : maxflow_ref

    genat = Dict(i => 0.0 for i in ids)
    for r in eachrow(generation); genat[r.node] = get(genat, r.node, 0.0) + r.gen; end
    loadat = Dict(r.bus_i => Float64(r.pd) for r in eachrow(bus))
    slack = bus[bus.type .== 3, :bus_i][1]
    maxact = max(maximum(genat[i] + loadat[i] for i in ids), 1e-6)

    # ---- the conduits, drawn as a soft glow then a core ------------------
    for r in eachrow(flows)
        f = r.flow
        lim = branch[branch.id .== r.id, :ratea][1]
        util = (lim >= unlimited || lim <= 0) ? abs(f) / maxflow * 0.30 : abs(f) / lim
        a, b = f >= 0 ? (r.fbus, r.tbus) : (r.tbus, r.fbus)
        x1, y1 = coords[a]; x2, y2 = coords[b]
        col = heat(util; cool=cool, warm=warm, hot=hot)
        w = 1.0 + 5.0 * clamp(abs(f) / maxflow, 0.0, 1.0)
        # glow halo: three passes, wide and faint to narrow and bright
        plot!(p, [x1, x2], [y1, y2]; lw = w * 4.5, color = col, alpha = 0.10)
        plot!(p, [x1, x2], [y1, y2]; lw = w * 2.2, color = col, alpha = 0.20)
        plot!(p, [x1, x2], [y1, y2]; lw = w,       color = col, alpha = 0.75)
    end

    # ---- LAYER 2: the carriers -------------------------------------------
    px = Float64[]; py = Float64[]; pc = RGB[]; ps = Float64[]
    for r in eachrow(flows)
        f = r.flow
        abs(f) < 1e-9 && continue
        lim = branch[branch.id .== r.id, :ratea][1]
        util = (lim >= unlimited || lim <= 0) ? abs(f) / maxflow * 0.30 : abs(f) / lim
        a, b = f >= 0 ? (r.fbus, r.tbus) : (r.tbus, r.fbus)
        x1, y1 = coords[a]; x2, y2 = coords[b]
        seglen = sqrt((x2 - x1)^2 + (y2 - y1)^2)
        rel = clamp(abs(f) / maxflow, 0.0, 1.0)
        n = max(1, round(Int, density * seglen / span * (0.35 + 0.65 * rel)))
        speed = 0.45 + 1.6 * clamp(util, 0.0, 1.0)      # congested = visibly fast
        col = heat(util; cool=cool, warm=warm, hot=hot)
        nx = -(y2 - y1) / seglen; ny = (x2 - x1) / seglen     # unit normal
        for k in 0:(n - 1)
            u = mod(k / n + stream_offset[r.id] + phase * speed, 1.0)
            # keep carriers clear of the bus markers at each end
            u = 0.09 + 0.82 * u
            j = jitter * span * 0.006 * carrier_jit[r.id, 1 + k % 96]
            push!(px, x1 + u * (x2 - x1) + nx * j)
            push!(py, y1 + u * (y2 - y1) + ny * j)
            push!(pc, col); push!(ps, 1.6 + 3.4 * rel)
        end
    end
    if !isempty(px)
        scatter!(p, px, py; ms = ps .* 2.2, color = pc, alpha = 0.13,
                 markerstrokewidth = 0)
        scatter!(p, px, py; ms = ps, color = pc, alpha = 0.95,
                 markerstrokewidth = 0)
    end

    # ---- the junction boxes ---------------------------------------------
    for i in ids
        x, y = coords[i]
        g = genat[i]; d = loadat[i]; net = g - d
        ms = 7 + 12 * ((g + d) / maxact)
        col = net > 1e-6 ? C_GEN : (net < -1e-6 ? C_LOAD : C_JUNC)
        scatter!(p, [x], [y]; ms = ms * 2.6, color = col, alpha = 0.10, markerstrokewidth = 0)
        scatter!(p, [x], [y]; ms = ms * 1.7, color = col, alpha = 0.18, markerstrokewidth = 0)
        scatter!(p, [x], [y]; ms = ms, color = col, alpha = 1.0,
                 shape = i == slack ? :rect : :circle,
                 markerstrokecolor = BG, markerstrokewidth = 1.5)
        annotate!(p, x, y, text(string(i), 10, RGB(0.06,0.07,0.08), :center, :bold))
    end

    # ---- the readout, in its own band of sky -----------------------------
    tx = xlim[1] + 0.035 * (xlim[2] - xlim[1])
    ty = ylim[2] - 0.045 * span
    if !isempty(title)
        # Shrink the headline until it fits the canvas. The IEEE 14-bus layout
        # is tall and narrow, so a title tuned on a wide canvas gets guillotined
        # at the right edge; measuring instead of guessing avoids that.
        avail = 0.93 * size[1]                      # px of usable width
        fs = 12
        while fs > 9 && length(title) * 0.60 * fs > avail
            fs -= 1
        end
        annotate!(p, tx, ty, text(title, fs, C_TEXT, :left, :bold))
        ty -= 0.062 * span
    end
    for (lab, val) in hud
        annotate!(p, tx, ty, text(lab, 11, C_DIM, :left))
        annotate!(p, tx + 0.26 * (xlim[2] - xlim[1]), ty, text(val, 12, C_TEXT, :left, :bold))
        ty -= 0.055 * span
    end
    return p
end
