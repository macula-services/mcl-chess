"""Generate mcl-chess's C4 diagrams into assets/.

Run:  python3 architecture/c4_diagrams.py

  c4-context.svg      Level 1: the agents, the referee, the mesh
  c4-containers.svg   Level 2: the service on its box, its three departments
  c4-components.svg   Level 3: inside the referee

Colours are plain classes with a prefers-color-scheme: dark block, no CSS
custom properties (rsvg-convert renders those black), so the SVGs render the
same on GitHub, in IDE previews and through rsvg-convert. After a change,
render each (rsvg-convert -w 1400 assets/c4-context.svg -o /tmp/c.png) and
look at it; keep architecture/README.md's tables in step.

Level 4 is the code table in architecture/README.md, not a picture: the
aggregate record, its state module and the status flags are clearer as a
table than as boxes, and they change with the code.
"""
import os
from xml.sax.saxutils import escape

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "assets")

SANS = '"Atkinson Hyperlegible", "Segoe UI", system-ui, -apple-system, Helvetica, Arial, sans-serif'
MONO = '"JetBrains Mono", ui-monospace, Menlo, Consolas, monospace'

# Element kinds, each (light fill, light stroke, dark fill, dark stroke).
KINDS = {
    "b-sys": ("#F5E9CC", "#A56F0A", "#3A2E13", "#E3AA3C"),   # in scope
    "b-per": ("#E3EBF2", "#3B5B7A", "#1D2A36", "#8EB4D8"),   # person
    "b-mac": ("#E6E4EE", "#5E5A78", "#26243A", "#A9A4C8"),   # Macula infrastructure
    "b-ext": ("#ECEFED", "#8A9791", "#1C2421", "#7D8B85"),   # external system
    "b-cmp": ("#FFFFFF", "#8A9791", "#171F1C", "#7D8B85"),   # component or container
}

STYLE = f"""<style>
.t-name {{ font-family: {SANS}; font-size: 15px; font-weight: 700; }}
.t-desc {{ font-family: {SANS}; font-size: 12.5px; }}
.t-rel {{ font-family: {SANS}; font-size: 11.5px; paint-order: stroke; stroke-width: 4px; stroke-linejoin: round; }}
.t-code {{ font-family: {MONO}; font-size: 13px; font-weight: 600; }}
.t-type {{ font-family: {MONO}; font-size: 11.5px; }}
.t-bound {{ font-family: {MONO}; font-size: 12px; font-weight: 600; }}
.t-leg {{ font-family: {SANS}; font-size: 12px; }}
.edge {{ fill: none; stroke-width: 1.25; }}
.edge-later {{ fill: none; stroke-width: 1.25; stroke-dasharray: 5 4; }}
.bg {{ fill: #FFFFFF; }}
""" + "".join(f".{k} {{ fill: {v[0]}; stroke: {v[1]}; stroke-width: {2 if k == 'b-sys' else 1.25}; }}\n" for k, v in KINDS.items()) + """\
.b-later { fill: none; stroke: #8A9791; stroke-width: 1.25; stroke-dasharray: 5 4; }
.bound { fill: none; stroke: #B3BDB8; stroke-width: 1; }
.head { fill: #3B5B7A; }
.t-name, .t-code { fill: #16201D; }
.t-type, .t-bound, .t-leg { fill: #66736E; }
.t-desc { fill: #34413C; }
.t-rel { fill: #66736E; stroke: #FFFFFF; }
.edge, .edge-later { stroke: #8A9791; }
.arrowhead { fill: #8A9791; }
@media (prefers-color-scheme: dark) {
.bg { fill: #171F1C; }
""" + "".join(f".{k} {{ fill: {v[2]}; stroke: {v[3]}; }}\n" for k, v in KINDS.items()) + """\
.b-later { stroke: #7D8B85; }
.bound { stroke: #4A5752; }
.head { fill: #8EB4D8; }
.t-name, .t-code { fill: #E6ECE9; }
.t-type, .t-bound, .t-leg { fill: #93A09A; }
.t-desc { fill: #C3CDC8; }
.t-rel { fill: #93A09A; stroke: #171F1C; }
.edge, .edge-later { stroke: #7D8B85; }
.arrowhead { fill: #7D8B85; }
}
</style>"""

DEFS = ('<defs><marker id="a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" '
        'orient="auto-start-reverse"><path class="arrowhead" d="M0 0L10 5L0 10z"/></marker></defs>')

LEGEND = [("b-sys", "In scope"), ("b-mac", "Macula infrastructure"),
          ("b-ext", "External system"), ("b-cmp", "Container or component"),
          ("b-later", "Planned, not built")]
BOUNDARY = ("bound", "Boundary")


class Diagram:
    def __init__(self, name, title, w, h):
        self.name, self.title, self.w, self.h, self.parts = name, title, w, h, []

    def text(self, cls, x, y, s, anchor=None, rotate=None):
        a = f' text-anchor="{anchor}"' if anchor else ""
        r = f' transform="rotate({rotate} {x} {y})"' if rotate is not None else ""
        self.parts.append(f'<text class="{cls}" x="{x}" y="{y}"{a}{r}>{escape(s)}</text>')

    def box(self, cls, x, y, w, h, name, kind, desc, person=False, code=False):
        self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="{w}" height="{h}" rx="10"/>')
        tx = x + 16
        if person:
            self.parts.append(f'<circle class="head" cx="{x + 26}" cy="{y + 24}" r="9"/>')
            tx = x + 44
        self.text("t-code" if code else "t-name", tx, y + 28, name)
        self.text("t-type", tx, y + 46, kind)
        for i, line in enumerate(desc):
            self.text("t-desc", x + 16, y + 70 + 16 * i, line)

    def bound(self, x, y, w, h, label):
        self.parts.append(f'<rect class="bound" x="{x}" y="{y}" width="{w}" height="{h}" rx="12"/>')
        self.text("t-bound", x + 16, y + 22, label)

    def edge(self, d, later=False):
        self.parts.append(f'<path class="{"edge-later" if later else "edge"}" d="{d}" marker-end="url(#a)"/>')

    def legend(self, y, boundary=True):
        x = 24
        for cls, label in LEGEND + ([BOUNDARY] if boundary else []):
            self.parts.append(f'<rect class="{cls}" x="{x}" y="{y}" width="22" height="14" rx="3"/>')
            self.text("t-leg", x + 30, y + 12, label)
            x += 34 + 6.6 * len(label)

    def write(self):
        svg = [f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" role="img" '
               f'aria-label="{escape(self.title)}">', f"<title>{escape(self.title)}</title>", STYLE, DEFS,
               f'<rect class="bg" x="0" y="0" width="{self.w}" height="{self.h}"/>'] + self.parts + ["</svg>", ""]
        with open(os.path.join(OUT, self.name), "w") as f:
            f.write("\n".join(svg))


def context():
    """Level 1. The agents, the harness they call through, the referee, and the
    matchmaker that is not this division."""
    d = Diagram("c4-context.svg", "mcl-chess system context", 1000, 790)
    d.box("b-ext", 40, 40, 280, 110, "Player A's agent", "[External system]",
          ["An agent that picks moves. Calls", "the referee; the seat claim is its", "consent to the time control"])
    d.box("b-ext", 360, 40, 280, 220, "macula-mcp", "[External: each agent's harness]",
          ["How an agent reaches the mesh and", "decides: presence, capability calls,",
           "and the scheduler it waits on.", "", "The thinking half of the game lives", "here. The referee never calls a",
           "model, never picks a move, and", "never wakes an agent."])
    d.box("b-ext", 680, 40, 280, 110, "Player B's agent", "[External system]",
          ["The other seat. Same shape: it", "claims a color, moves on its turn", "or forfeits on the clock"])
    d.box("b-ext", 40, 320, 280, 130, "Anyone watching", "[External system]",
          ["Other agents, board viewers, a", "future reputation division:",
           "mesh_watch the facts, never the", "service's private state"])
    d.box("b-mac", 360, 320, 280, 130, "Macula mesh", "[Macula infrastructure]",
          ["Pinned stations are the entry", "points (QUIC); the union of",
           "stations routes an org procedure;", "the facts travel its topics"])
    d.box("b-sys", 680, 320, 280, 130, "mcl-chess", "[mcl_om mesh service, own box]",
          ["The referee: validates, clocks and", "sequences one game, records a",
           "disputable transcript, publishes", "facts. One service, one truth"])
    d.box("b-mac", 360, 530, 280, 110, "macula-realm", "[Macula infrastructure]",
          ["Admits the org mcl-chess and issues", "the D25 provider grant per procedure;", "a call without one is refused"])
    d.box("b-later", 680, 530, 280, 110, "Future matchmaker", "[planned: separate division]",
          ["Decides who plays whom, then calls", "initiate_game with pre-assigned",
           "seats. Nothing here pairs players"])
    d.edge("M320 95H360"); d.text("t-rel", 340, 86, "calls,", anchor="middle"); d.text("t-rel", 340, 120, "signed", anchor="middle")
    d.edge("M680 95H640"); d.text("t-rel", 660, 86, "calls,", anchor="middle"); d.text("t-rel", 660, 120, "signed", anchor="middle")
    d.edge("M500 260V320"); d.text("t-rel", 508, 296, "joins the mesh through a station")
    d.edge("M640 345H680"); d.text("t-rel", 660, 337, "routes", anchor="middle"); d.text("t-rel", 660, 371, "calls", anchor="middle")
    d.edge("M680 395H640"); d.text("t-rel", 660, 413, "facts", anchor="middle")
    d.edge("M360 375H320"); d.text("t-rel", 340, 367, "topics", anchor="middle")
    d.edge("M560 530V470H712V450"); d.text("t-rel", 570, 512, "admits, grants")
    d.edge("M820 530V450", later=True); d.text("t-rel", 812, 496, "initiate_game, seats assigned", anchor="end")
    d.text("t-desc", 40, 672, "Trust: the referee is one service both sides call, so neither has to trust the other's agent to keep the rules. Every")
    d.text("t-desc", 40, 690, "decision is an event in the service's own store, and every event a fact on the mesh: a game replays and is disputed from")
    d.text("t-desc", 40, 708, "the transcript alone. Attribution is by the wire, never the payload, so a caller cannot claim the other seat. A node that")
    d.text("t-desc", 40, 726, "stops moving forfeits on the clock both seats accepted by claiming.")
    d.legend(762)
    d.write()


def containers():
    """Level 2. One box, one OCI container, three departments and a store."""
    d = Diagram("c4-containers.svg", "mcl-chess containers", 1080, 720)
    d.bound(24, 40, 576, 560, "The mcl-chess box [mcl_om mesh service, one OCI container]")
    d.box("b-sys", 44, 76, 536, 110, "mcl_chess (boot app)", "[OTP release, mcl_om_service]",
          ["Opens the event store before mcl_om:boot/1, supervises the three departments,",
           "/health, and advertises the capabilities, naming any missing D25 grant."])
    d.box("b-cmp", 44, 206, 168, 120, "play_games", "[CMD: commands, events, policies]",
          ["One desk per slice, from", "game initiation to archive.",
           "The only writer of events"])
    d.box("b-cmp", 228, 206, 168, 120, "project_games", "[PRJ: projections]",
          ["One projection per event,", "writing the read model and",
           "the computed status label"])
    d.box("b-cmp", 412, 206, 168, 120, "query_games", "[QRY: read model]",
          ["get_game_by_id, by status,", "page, by player. Answers",
           "from SQLite, never events"])
    d.box("b-cmp", 44, 346, 250, 120, "Event store", "[reckon_db, volume /data]",
          ["The source of truth: one stream", "per game, replayed to rebuild",
           "the aggregate on demand"])
    d.box("b-cmp", 310, 346, 270, 120, "Read model", "[SQLite through esqlite]",
          ["Board, move list, clocks, status", "and label: what queries serve and",
           "what a board viewer rebuilds from"])
    d.box("b-cmp", 44, 486, 536, 96, "Identity and realm admission", "[node identity key, D25 grants]",
          ["The identity key names the service to the realm; a procedure", "without its grant is refused at the boundary."])
    d.box("b-mac", 780, 76, 280, 120, "Macula mesh", "[Macula infrastructure]",
          ["Entry through pinned stations (QUIC);", "capabilities advertised as",
           "mcl-chess/<verb>; facts on topics"])
    d.box("b-mac", 780, 216, 280, 120, "macula-realm", "[Macula infrastructure]",
          ["Org mcl-chess, the node endorsement", "and one D25 grant per published",
           "procedure"])
    d.box("b-ext", 780, 356, 280, 120, "ghcr.io", "[External: signed images]",
          ["The release image, by digest, signed", "and attested; the reconciler",
           "refuses an unsigned one on enforce"])
    d.box("b-later", 780, 496, 280, 120, "macula-fleet", "[planned: WP8, out of this range]",
          ["The fleet definition: edge config,", "reconcile.manifest entry, digest",
           "pin, canary first"])
    d.edge("M128 186V206"); d.text("t-rel", 136, 200, "supervises")
    d.edge("M312 186V206"); d.edge("M496 186V206")
    d.edge("M128 326V346"); d.text("t-rel", 136, 340, "appends")
    d.edge("M360 326V346"); d.text("t-rel", 368, 340, "writes")
    d.edge("M496 346V326"); d.text("t-rel", 504, 340, "reads")
    d.edge("M294 406H310")
    d.edge("M580 110H780"); d.text("t-rel", 680, 96, "advertises the capabilities", anchor="middle")
    d.text("t-rel", 680, 142, "and publishes the facts", anchor="middle")
    d.edge("M780 250L600 178"); d.text("t-rel", 690, 250, "admits, grants", anchor="middle")
    d.edge("M780 400L600 474"); d.text("t-rel", 690, 452, "the image this box runs", anchor="middle")
    d.edge("M920 496V476", later=True); d.text("t-rel", 928, 492, "pins")
    d.text("t-desc", 40, 636, "One container, one box: the v1 horizon is a single service node hosting many concurrent games, each its own aggregate and")
    d.text("t-desc", 40, 654, "its own clock instance. Scaling out to several nodes is a later design, not v1; the per-game independence keeps it possible.")
    d.legend(692)
    d.write()


def components():
    """Level 3. Inside the referee: the aggregate, the desks, the policies,
    the clock, the facts and the rules."""
    d = Diagram("c4-components.svg", "mcl-chess components", 1000, 820)
    d.bound(16, 40, 968, 740, "play_games [Container, CMD]")
    d.box("b-sys", 32, 70, 456, 110, "game_aggregate, game_state, game_status.hrl", "[evoq_aggregate + state module]",
          ["Replays its own stream to the state: seats, position, to_move,",
           "ply, clocks, status flags, outcome. Every guard lives in a",
           "maybe_* handler, never in a caller."], code=True)
    d.box("b-cmp", 512, 70, 456, 110, "mcl_chess_facts", "[the only module naming the mesh SDK]",
          ["Owns every topic and every translation: the facts contract in",
           "one place, pinned by mcl_chess_facts_tests. Desks emit through",
           "it; nothing else names a topic."], code=True)
    d.box("b-cmp", 32, 206, 210, 96, "initiate_game/", "[desk: birth]", ["game_initiated_v1"], code=True)
    d.box("b-cmp", 262, 206, 210, 96, "claim_seat/", "[desk: seats]",
          ["seat_claimed_v1,", "seat_refused_v1"], code=True)
    d.box("b-cmp", 492, 206, 210, 96, "start_game/", "[desk: start]", ["game_started_v1"], code=True)
    d.box("b-cmp", 712, 206, 210, 96, "submit_move/", "[desk: play]",
          ["move_played_v1,", "move_refused_v1"], code=True)
    d.box("b-cmp", 32, 322, 210, 96, "resign_game/", "[desk: play]", ["game_ended_v1"], code=True)
    d.box("b-cmp", 262, 322, 210, 96, "withdraw_game/", "[desk: death]",
          ["game_archived_v1,", "pre-start only"], code=True)
    d.box("b-cmp", 492, 322, 210, 96, "end_game/, flag_clock/",
          "[internal: dispatched]",
          ["game_ended_v1,", "clock_flagged_v1"], code=True)
    d.box("b-cmp", 712, 322, 210, 96, "archive_game/", "[desk: death]",
          ["game_archived_v1,", "after retention"], code=True)
    d.box("b-cmp", 32, 480, 456, 132, "on_* policies", "[evoq_event_handler, replay_policy skip]",
          ["on_seat_claimed_v1_maybe_start_game,",
           "on_move_played_v1_maybe_end_game,",
           "on_clock_flagged_v1_maybe_end_game."], code=True)
    d.box("b-cmp", 512, 480, 456, 132, "game_clock_pm, game_retention_pm", "[evoq_process_manager, one per game]",
          ["The clock: white's clock starts at game_started_v1; the",
           "mover's stops and the opponent's starts on move_played_v1;",
           "both stop at game_ended_v1, and a deadline that fires is a",
           "flag. Retention: the window, then the death slice."], code=True)
    d.box("b-cmp", 32, 648, 456, 126, "mcl_chess_rules", "[Rust NIF over cozy-chess, stateless]",
          ["validate_move(Fen, Uci), apply_move(Fen, Uci) -> Fen', the Zobrist",
           "hash and the halfmove-reset flag, position_hash(Fen), status(Fen,",
           "Halfmove) -> active | checkmate | stalemate | insufficient_material",
           "| seventy_five_moves. Legal-only generation."], code=True)
    d.box("b-mac", 512, 648, 456, 126, "evoq 1.27.0", "[the only application surface]",
          ["evoq_command, evoq_event, evoq_aggregate, evoq_event_handler,",
           "evoq_process_manager, evoq_command_router, evoq_bit_flags. The",
           "adapter is named in sys.config only: no desk touches the store."])
    d.edge("M137 180V206"); d.text("t-rel", 145, 198, "every handler guards on the state")
    d.edge("M830 206V180"); d.text("t-rel", 822, 200, "emits through", anchor="end")
    d.edge("M482 480V418"); d.text("t-rel", 474, 452, "dispatches the next", anchor="end")
    d.text("t-rel", 474, 470, "command into a desk", anchor="end")
    d.edge("M597 480V418"); d.text("t-rel", 605, 470, "flag_clock_v1")
    d.edge("M120 612V648"); d.text("t-rel", 128, 634, "asks for status")
    d.legend(792)
    d.write()


if __name__ == "__main__":
    for make in (context, containers, components):
        make()
