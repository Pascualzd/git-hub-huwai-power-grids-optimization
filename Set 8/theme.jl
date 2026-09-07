#=
theme.jl -- one visual language for every figure in Set 8.

Colours are not chosen by taste. The categorical slots below were checked with a
colour-vision-deficiency validator: worst all-pairs separation is dE 9.2 under
deuteranopia and dE 24.0 under normal vision, both clear of the thresholds where
two series stop being distinguishable. Blue/orange/aqua is therefore safe for
readers with the common forms of colour blindness, and every multi-series chart
also carries a legend so identity never rests on hue alone.

A NOTE ON TEXT WEIGHT -- measured, not assumed
----------------------------------------------
The obvious way to make labels readable is to set them bold. On the GR backend
that BACKFIRES, and it is worth recording why, because it is the reason earlier
figures in this project had "thin grey letters".

Rendering the same string at the same size, then counting solid ink pixels:

    text(s, 26, black)                -> darkest pixel (0,0,0),    2731 ink px
    text(s, 26, black, :bold)         -> darkest pixel (68,68,68), 1599 ink px
    text(s, 26, black, "Helvetica")   -> darkest pixel (68,68,68), 2267 ink px

GR has no bold face for its default font, so `:bold` silently falls back to a
substitute that is both LIGHTER IN COLOUR and THINNER IN STROKE -- literally
the opposite of what was asked for. Naming any font family does the same.

So every label in Set 8 is drawn PLAIN, in the default family, in true black,
and weight comes from SIZE alone. That yields 70% more ink on the page than the
"bold" version of the same label.
=#

using Plots, Printf

# --- ink ------------------------------------------------------------------
const INK        = RGB(0.043, 0.043, 0.043)   # #0b0b0b  primary text
const INK_2      = RGB(0.322, 0.318, 0.306)   # #52514e  secondary text
const INK_MUTED  = RGB(0.537, 0.529, 0.506)   # #898781  axis labels
const GRIDLINE   = RGB(0.882, 0.878, 0.851)   # #e1e0d9  hairline grid
const SURFACE    = RGB(0.988, 0.988, 0.984)   # #fcfcfb  chart surface

# --- categorical slots (validated, in fixed order) ------------------------
const C1 = RGB(0.165, 0.471, 0.839)   # #2a78d6  blue
const C2 = RGB(0.922, 0.408, 0.204)   # #eb6834  orange
const C3 = RGB(0.106, 0.686, 0.478)   # #1baf7a  aqua

# --- status (reserved; never used as a series colour) ---------------------
const S_CRIT = RGB(0.816, 0.231, 0.231)   # #d03b3b  shedding / failure
const S_WARN = RGB(0.980, 0.698, 0.098)   # #fab219  at-limit / congestion
const S_GOOD = RGB(0.047, 0.639, 0.047)   # #0ca30c  served / healthy

"""Sequential blue ramp, light -> dark, for magnitude encodings."""
const BLUE_RAMP = cgrad([RGB(0.804,0.886,0.984), RGB(0.427,0.655,0.929),
                         RGB(0.165,0.471,0.839), RGB(0.094,0.310,0.545)])

"""
    setup_theme!()

Install the Set 8 look as the Plots.jl default: recessive grid, dark bold text,
generous margins so nothing is guillotined at the edge of a slide.
"""
function setup_theme!()
    default(
        # No fontfamily override on purpose -- see the header note. Naming a
        # family costs contrast on this backend.
        background_color  = SURFACE,
        foreground_color  = INK,
        titlefontsize     = 13,
        titlefontcolor    = INK,
        guidefontsize     = 11,
        guidefontcolor    = INK_2,
        tickfontsize      = 10,
        tickfontcolor     = INK_2,
        legendfontsize    = 10,
        legendfontcolor   = INK,
        grid              = true,
        gridcolor         = GRIDLINE,
        gridalpha         = 0.9,
        gridlinewidth     = 0.8,
        foreground_color_axis   = RGB(0.765,0.761,0.718),
        foreground_color_border = RGB(0.765,0.761,0.718),
        linewidth         = 2,
        markerstrokewidth = 0,
        bottom_margin     = 7Plots.mm,
        left_margin       = 7Plots.mm,
        top_margin        = 4Plots.mm,
        right_margin      = 5Plots.mm)
    return nothing
end

"""
    pct(x)

Format a probability as a percentage string with sensible precision: rare events
keep two decimals so 0.03% does not print as 0%.
"""
pct(x) = x >= 0.10 ? @sprintf("%.1f%%", 100x) :
         x >= 0.01 ? @sprintf("%.2f%%", 100x) :
                     @sprintf("%.3f%%", 100x)

"""
    grouped_bar(labels, M; colors, series, kwargs...)

Dodged bar chart without pulling in StatsPlots. `M` is groups x series; each
column becomes one series, drawn side by side within its group.

Bars carry a 2px surface-coloured edge so adjacent fills never touch -- the
gap is what lets the eye separate two bars of similar height.
"""
function grouped_bar(labels, M::AbstractMatrix; colors, series, kwargs...)
    n, k = size(M)
    bw = 0.80 / k
    p = plot(; kwargs...)
    for j in 1:k
        xs = (1:n) .+ (j - (k + 1) / 2) * bw
        bar!(p, xs, M[:, j]; bar_width = bw * 0.90, color = colors[j],
             label = series[j], linecolor = SURFACE, linewidth = 2)
    end
    xticks!(p, collect(1.0:n), labels)
    xlims!(p, 0.4, n + 0.6)
    return p
end

"""
    grouped_positions(n, k, j; width)

X positions of series `j` of `k` in a `grouped_bar` with `n` groups -- so value
labels can be placed over the bars they belong to.
"""
grouped_positions(n, k, j; width = 0.80) =
    (1:n) .+ (j - (k + 1) / 2) * (width / k)

"""
    label_bars!(p, xs, ys, labels; above, color, fs)

Direct-label a bar series. Charts in this set label their bars rather than
forcing the reader to bounce between a bar top and an axis tick.
"""
function label_bars!(p, xs, ys, labels; above = 0.02, color = INK, fs = 10)
    span = maximum(ys) - min(0.0, minimum(ys))
    for (x, y, l) in zip(xs, ys, labels)
        annotate!(p, x, y + above * span, text(l, fs, color, :center))
    end
    return p
end
