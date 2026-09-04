#=
gridviz.jl  --  Drawing the solved grid as a picture.

WHAT THIS FILE IS FOR
---------------------
`dcopf` gives you three tables of numbers. Numbers do not show you *where* the
power is squeezing through. This file turns the solution into a map:

    bus      ->  a junction box you can point at
    line     ->  a pipe between junction boxes
    flow     ->  an arrow drawn ON that pipe, thickness = how much is moving
    rateA    ->  the pipe's diameter; colour = how close to bursting

Nothing here changes the optimisation. It only reads the solution.

DEPENDENCIES: Plots, DataFrames  (both already imported by OPT part 2.jl)

USAGE
-----
    include("gridviz.jl")
    p = plot_network(bus, branch, solution.generation, solution.flows;
                     coords = IEEE14_COORDS, title = "IEEE 14-bus DC-OPF")
    savefig(p, "network.png")
=#

using Plots, DataFrames, Printf

# ---------------------------------------------------------------------------
# 1. LAYOUT: where do we put the junction boxes on the page?
# ---------------------------------------------------------------------------

"""
    spring_layout(ids, edges; iters, seed)

Fruchterman-Reingold force layout. The mechanical picture:

  * every node is a small magnet that PUSHES every other node away
      (repulsion ~ k^2 / distance)
  * every line is a spring that PULLS its two endpoints together
      (attraction ~ distance^2 / k)

Let the whole thing shake for `iters` steps, cooling down each step (like
tapping a tray of ball bearings until they settle). `k` is the natural
resting distance between two unconnected nodes.

Returns Dict(bus_id => (x, y)).
"""
function spring_layout(ids::Vector, edges::Vector{<:Tuple}; iters::Int = 600, seed::Int = 42)
    n = length(ids)
    pos = Dict{Any,Int}(id => i for (i, id) in enumerate(ids))

    # Deterministic start: spread the nodes evenly around a circle, so the
    # picture is the same every time you run the script.
    x = [cos(2pi * (i - 1) / n) for i in 1:n]
    y = [sin(2pi * (i - 1) / n) for i in 1:n]
    # tiny deterministic jitter breaks perfect symmetry (springs need a nudge)
    rng = seed
    for i in 1:n
        rng = (1103515245 * rng + 12345) % 2147483648
        x[i] += 1e-3 * (rng / 2147483648 - 0.5)
        rng = (1103515245 * rng + 12345) % 2147483648
        y[i] += 1e-3 * (rng / 2147483648 - 0.5)
    end

    k = sqrt(1.0 / n)                # natural spring length
    t = 0.1                          # starting "temperature" = max step size

    E = [(pos[a], pos[b]) for (a, b) in edges if haskey(pos, a) && haskey(pos, b)]

    for _ in 1:iters
        dx = zeros(n); dy = zeros(n)

        # --- repulsion: every node pushes every other node ---
        for i in 1:n, j in (i+1):n
            ux = x[i] - x[j]; uy = y[i] - y[j]
            d2 = max(ux^2 + uy^2, 1e-9)
            d  = sqrt(d2)
            f  = k^2 / d2            # force magnitude
            dx[i] += f * ux / d; dy[i] += f * uy / d
            dx[j] -= f * ux / d; dy[j] -= f * uy / d
        end

        # --- attraction: each line pulls its endpoints together ---
        for (i, j) in E
            ux = x[i] - x[j]; uy = y[i] - y[j]
            d  = max(sqrt(ux^2 + uy^2), 1e-9)
            f  = d^2 / k
            dx[i] -= f * ux / d; dy[i] -= f * uy / d
            dx[j] += f * ux / d; dy[j] += f * uy / d
        end

        # --- move, but never further than the current temperature ---
        for i in 1:n
            d = max(sqrt(dx[i]^2 + dy[i]^2), 1e-9)
            step = min(d, t)
            x[i] += dx[i] / d * step
            y[i] += dy[i] / d * step
        end
        t *= 0.985                   # cool down
    end

    return Dict(id => (x[pos[id]], y[pos[id]]) for id in ids)
end

# Hand-placed coordinates for the two networks used in this project.
# Hand-placing beats the spring layout when a canonical one-line diagram
# already exists in every textbook -- the reader recognises the shape.

const BUS3_COORDS = Dict(
    1 => (0.0, 0.0),
    2 => (2.0, 0.0),
    3 => (1.0, -1.7),
)

const IEEE14_COORDS = Dict(
    1  => (1.0, 0.4),
    2  => (2.2, 1.6),
    3  => (3.7, 1.1),
    4  => (3.0, 2.7),
    5  => (1.7, 2.6),
    6  => (0.9, 3.9),
    7  => (3.9, 3.6),
    8  => (4.9, 3.9),
    9  => (3.1, 4.6),
    10 => (2.4, 5.1),
    11 => (1.5, 4.7),
    12 => (0.4, 4.8),
    13 => (1.1, 5.7),
    14 => (2.5, 6.0),
)

# ---------------------------------------------------------------------------
# 2. THE MAP ITSELF
# ---------------------------------------------------------------------------

_lerp(a, b, t) = a .+ (b .- a) .* t

"""
Colour of a pipe given how full it is (0 = empty, 1 = at its rating).
Green -> amber -> red, so a congested corridor jumps out of the page.
"""
function _load_color(util)
    u = clamp(util, 0.0, 1.0)
    return u < 0.5 ? RGB(_lerp((0.16, 0.55, 0.29), (0.90, 0.68, 0.10), u / 0.5)...) :
                     RGB(_lerp((0.90, 0.68, 0.10), (0.78, 0.13, 0.13), (u - 0.5) / 0.5)...)
end

"""
    plot_network(bus, branch, generation, flows; kwargs...)

Draw the solved network.

Arguments
  bus         : DataFrame with :bus_i, :pd, :type  (type 3 = slack)
  branch      : DataFrame with :id, :fbus, :tbus, :ratea
  generation  : solution.generation  (:node, :gen)
  flows       : solution.flows       (:id, :fbus, :tbus, :flow)

Keywords
  coords      : Dict(bus_id => (x,y)); if omitted a spring layout is computed
  title       : plot title
  show_limits : annotate each line with "flow / rateA"
  unlimited   : rateA values >= this are treated as "no limit" (default 9000)

Reading the picture
  node size   : how much power the bus handles (generation + load)
  node colour : green = net exporter (a source), red = net importer (a sink),
                grey = pure junction.  Square marker = slack/reference bus.
  edge width  : magnitude of flow, relative to the biggest flow in the case
  edge colour : |flow| / rateA -- green slack, red congested
  arrow       : the direction power is ACTUALLY travelling in the solution
"""
function plot_network(bus, branch, generation, flows;
                      coords = nothing,
                      title = "DC-OPF solution",
                      show_limits = true,
                      unlimited = 9000.0,
                      size = nothing)

    ids   = collect(bus.bus_i)
    edges = [(branch[l, :fbus], branch[l, :tbus]) for l in 1:nrow(branch)]
    xy    = coords === nothing ? spring_layout(ids, edges) : coords

    # Geometry of the page. Every text offset below is expressed as a fraction
    # of `span`, so the picture looks the same whether the coordinates run
    # 0..2 (3-bus) or 0..6 (IEEE 14-bus).
    xs0 = [xy[i][1] for i in ids]; ys0 = [xy[i][2] for i in ids]
    xr  = maximum(xs0) - minimum(xs0); yr = maximum(ys0) - minimum(ys0)
    span = max(xr, yr, 1e-6)
    pad  = 0.12 * span
    # Choose canvas dimensions that match the network's own shape, so an
    # equal-aspect plot does not leave a band of dead white space.
    if size === nothing
        w = xr + 2pad; h = yr + 2pad
        base = 950
        size = w >= h ? (base, max(420, round(Int, base * h / w)) + 140) :
                        (max(520, round(Int, base * w / h)), base + 140)
    end

    # ---- per-bus bookkeeping -------------------------------------------
    genat  = Dict(i => 0.0 for i in ids)
    for r in eachrow(generation)
        genat[r.node] = get(genat, r.node, 0.0) + r.gen
    end
    loadat = Dict(r.bus_i => Float64(r.pd) for r in eachrow(bus))
    slack  = bus[bus.type .== 3, :bus_i][1]
    maxflow = maximum(abs.(flows.flow); init = 1.0)
    maxflow = maxflow < 1e-6 ? 1.0 : maxflow
    activity = [genat[i] + loadat[i] for i in ids]
    maxact   = maximum(activity; init = 1.0)
    maxact   = maxact < 1e-6 ? 1.0 : maxact

    p = plot(; title = title, titlefontsize = 13, legend = :outerbottom,
             legendcolumns = 4, legendfontsize = 8,
             framestyle = :none, aspect_ratio = :equal, size = size,
             background_color = :white, foreground_color = :black)

    # ---- 1. the pipes ---------------------------------------------------
    # Text is collected, not drawn, so it can be un-tangled afterwards.
    labels = NamedTuple[]     # (x, y, str, size, colour, bold)

    for r in eachrow(flows)
        f   = r.flow
        lim = branch[branch.id .== r.id, :ratea][1]
        util = lim >= unlimited || lim <= 0 ? abs(f) / maxflow * 0.35 : abs(f) / lim

        # always draw the arrow pointing the way the power really goes
        a, b = f >= 0 ? (r.fbus, r.tbus) : (r.tbus, r.fbus)
        (x1, y1) = xy[a]; (x2, y2) = xy[b]

        lw  = 1.2 + 6.5 * clamp(abs(f) / maxflow, 0.0, 1.0)
        col = _load_color(util)

        plot!(p, [x1, x2], [y1, y2]; lw = lw, color = col, label = "", alpha = 0.85)

        # arrowhead: a short stub drawn across the middle of the pipe
        if abs(f) > 1e-6
            ax1, ay1 = x1 + 0.40 * (x2 - x1), y1 + 0.40 * (y2 - y1)
            ax2, ay2 = x1 + 0.56 * (x2 - x1), y1 + 0.56 * (y2 - y1)
            plot!(p, [ax1, ax2], [ay1, ay2]; lw = lw, color = col,
                  arrow = arrow(:closed, 0.9, 0.9), label = "")
        end

        if show_limits
            # Start the label off the pipe, at right angles to it.
            ex, ey = x2 - x1, y2 - y1
            elen = max(sqrt(ex^2 + ey^2), 1e-9)
            nx, ny = -ey / elen, ex / elen
            ny < 0 && ((nx, ny) = (-nx, -ny))
            atlim = util >= 0.999
            push!(labels, (x = (x1 + x2) / 2 + 0.055 * span * nx,
                           y = (y1 + y2) / 2 + 0.055 * span * ny,
                           str = (lim >= unlimited || lim <= 0) ?
                                 @sprintf("%.0f", abs(f)) :
                                 @sprintf("%.0f/%.0f", abs(f), lim),
                           sz = 9,
                           col = atlim ? RGB(0.70, 0.10, 0.10) : RGB(0.02, 0.02, 0.05),
                           bold = true))
        end
    end

    # ---- 2. the junction boxes ------------------------------------------
    # Node captions start pushed radially OUTWARD from the middle of the
    # drawing, away from the tangle of lines in the centre.
    cx = sum(xs0) / length(xs0); cy = sum(ys0) / length(ys0)
    fixed = [(x, y) for (x, y) in ((xy[i][1], xy[i][2]) for i in ids)]  # obstacles

    for i in ids
        (x, y) = xy[i]
        g = genat[i]; d = loadat[i]; net = g - d
        ms = 9 + 13 * ((g + d) / maxact)
        col = net > 1e-6  ? RGB(0.13, 0.47, 0.24) :
              net < -1e-6 ? RGB(0.72, 0.20, 0.20) : RGB(0.55, 0.57, 0.60)
        shp = i == slack ? :rect : :circle
        scatter!(p, [x], [y]; ms = ms, color = col, markerstrokecolor = :white,
                 markerstrokewidth = 2, shape = shp, label = "")
        annotate!(p, x, y, text(string(i), 9, :white, :center, :bold))

        lbl = String[]
        g > 1e-6 && push!(lbl, @sprintf("G %.0f", g))
        d > 1e-6 && push!(lbl, @sprintf("L %.0f", d))
        if !isempty(lbl)
            ox, oy = x - cx, y - cy
            olen = sqrt(ox^2 + oy^2)
            (olen < 1e-6) && ((ox, oy, olen) = (0.0, -1.0, 1.0))
            r = 0.048 * span + 0.0016 * span * ms
            push!(labels, (x = x + r * ox / olen, y = y + r * oy / olen,
                           str = join(lbl, "  "), sz = 9,
                           col = RGB(0.05, 0.05, 0.07), bold = true))
        end
    end

    # ---- 2b. un-tangle the text -----------------------------------------
    # Every caption is a little tile that must not sit on another tile or on
    # a junction box. Let them shove each other apart for a few rounds --
    # same idea as the spring layout, but for labels only.
    lx = [l.x for l in labels]; ly = [l.y for l in labels]
    minsep  = 0.075 * span          # tile-to-tile clearance
    nodesep = 0.045 * span          # tile-to-junction clearance
    for _ in 1:120
        for i in eachindex(lx)
            dx = 0.0; dy = 0.0
            for j in eachindex(lx)
                i == j && continue
                ux = lx[i] - lx[j]; uy = ly[i] - ly[j]
                d = sqrt(ux^2 + uy^2)
                if d < minsep
                    d < 1e-9 && ((ux, uy, d) = (0.0, 1e-6, 1e-6))
                    push_ = (minsep - d) / d * 0.5
                    dx += ux * push_; dy += uy * push_
                end
            end
            for (nx0, ny0) in fixed
                ux = lx[i] - nx0; uy = ly[i] - ny0
                d = sqrt(ux^2 + uy^2)
                if d < nodesep
                    d < 1e-9 && ((ux, uy, d) = (0.0, 1e-6, 1e-6))
                    push_ = (nodesep - d) / d * 0.7
                    dx += ux * push_; dy += uy * push_
                end
            end
            lx[i] += clamp(dx, -0.02span, 0.02span)
            ly[i] += clamp(dy, -0.02span, 0.02span)
        end
    end
    for (k, l) in enumerate(labels)
        annotate!(p, lx[k], ly[k],
                  text(l.str, l.sz, l.col, :center, :bold))
    end

    # ---- 3. a legend you can actually read ------------------------------
    plot!(p, [], []; seriestype = :scatter, ms = 7, shape = :rect,
          color = RGB(0.13, 0.47, 0.24), label = "slack bus")
    plot!(p, [], []; seriestype = :scatter, ms = 7,
          color = RGB(0.13, 0.47, 0.24), label = "net supply")
    plot!(p, [], []; seriestype = :scatter, ms = 7,
          color = RGB(0.72, 0.20, 0.20), label = "net demand")
    plot!(p, [], []; seriestype = :scatter, ms = 7,
          color = RGB(0.55, 0.57, 0.60), label = "junction")
    plot!(p, [], []; lw = 4, color = _load_color(0.0),  label = "line: slack")
    plot!(p, [], []; lw = 4, color = _load_color(0.6),  label = "line: loaded")
    plot!(p, [], []; lw = 4, color = _load_color(1.0),  label = "line: AT LIMIT")

    allx = vcat(xs0, lx); ally = vcat(ys0, ly)
    plot!(p; xlims = (minimum(allx) - 0.5pad, maximum(allx) + 0.5pad),
             ylims = (minimum(ally) - 0.9pad, maximum(ally) + 0.5pad))
    return p
end

# ---------------------------------------------------------------------------
# 3. SUPPORTING CHARTS
# ---------------------------------------------------------------------------

"""Bar chart: who is generating, and how close to their ceiling."""
function plot_dispatch(gen, gencost, generation; title = "Dispatch vs capacity")
    labels = ["G$(r.id)\n@bus $(r.node)" for r in eachrow(generation)]
    used   = generation.gen
    cap    = [gen[gen.id .== r.id, :pmax][1] for r in eachrow(generation)]
    cost   = [gencost[gencost.id .== r.id, :c1][1] for r in eachrow(generation)]

    p = bar(labels, cap; label = "unused capacity", color = RGB(0.86, 0.87, 0.89),
            linecolor = :white, title = title, titlefontsize = 12,
            ylabel = "MW", legend = :topright, legendfontsize = 8)
    bar!(p, labels, used; label = "dispatched",
         color = RGB(0.17, 0.40, 0.62), linecolor = :white)
    for (i, u) in enumerate(used)
        annotate!(p, i, u + 0.05 * maximum(cap),
                  text(@sprintf("%.0f MW\n\$%.0f/MWh", u, cost[i]), 9, RGB(0.05, 0.05, 0.07), :center, :bold))
    end
    return p
end

"""Bar chart of the voltage phase angles -- the 'height map' of the grid."""
function plot_angles(angles; title = "Voltage phase angles (the grid's terrain)")
    deg = angles.theta .* (180 / pi)
    p = bar(string.("bus ", angles.bus), deg;
            label = "", color = RGB(0.35, 0.31, 0.60), linecolor = :white,
            title = title, titlefontsize = 12, ylabel = "degrees",
            xrotation = 45)
    hline!(p, [0]; color = :black, lw = 1, label = "")
    return p
end
