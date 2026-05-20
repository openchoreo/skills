# Writing frame content

The skill ships frames (CSS shell + slots) and a helper script (auto-injected). You write a fragment of HTML into `current/content/index.html` with a directive on the first line that picks the frame; the server splices your body into the matching frame and reloads the page.

```html
<!-- oc-frame: plan -->
… your content …
```

If the directive is missing, the server falls back to `assets/frame.html` (a plain branded shell). If your body starts with `<!doctype` or `<html>`, the server skips frame wrapping and serves it raw — escape hatch for one-off pages.

For the server / lifecycle / event details, see [`plan-preview.md`](plan-preview.md).

---

## Tags you write

All CSS is auto-injected. Don't write `<style>` blocks, inline `style="…"`, or class names from `components.css`. Two markup kinds:

1. **Plain HTML** for prose and structure — `<h2>` `<h3>` `<p>` `<ul>` `<table>` `<pre><code>` `<dl class="kv">` `<details>`. Styled for you.
2. **`<oc-*>` tags** for OpenChoreo blocks below. Rule: attributes carry label/kind; children carry the body.

| Tag | Attributes | Children | What it is |
| --- | --- | --- | --- |
| `<oc-rows>` | — | `<oc-onboard>`s | A bordered panel of spec rows — one per *Types & Traits* / *Projects & Components* section. Wrap a section's rows in it. |
| `<oc-onboard>` | `name` | `<p>` + optional `<oc-uses>` | One spec row. `name` = left-gutter title; `<p>` = a one-line description; `<oc-uses>` = a chip row. |
| `<oc-uses>` | `label` | `<oc-use>`s | A labelled chip row. `label` = the lowercase eyebrow text (e.g. `used by`, `uses`). |
| `<oc-use>` | `more` | text | One chip (a name). Add the bare `more` attr for the dashed "+N more" overflow chip. |
| `<oc-callout>` | `kind`, `label` | `<p>`, `<ul>` | Admonition box. `kind` = `note`/`info` (blue) · `tip`/`ok` (green) · `warn` (amber) · `danger` (red). `label` = the uppercase header. |
| `<oc-facts>` | — | `<oc-fact>`s | Flat observation list (used in Caveats). |
| `<oc-fact>` | `kind`, `title` | body | One observation. `title` is the heading, colored by `kind` (`warn`/`ok`/`danger`). |
| `<oc-tag>` | `kind` | text | Inline pill. `kind` = `ok`/`warn`/`brand`/`danger`. |
| `<oc-count>` | — | a number | Count pill, sits inside a section `<h3>`. |

---

## The two frames

The fit verdict + findings live in chat, never a frame. Two frames exist:

- **`plan`** (`content/index.html`) — architecture diagram + 4 fixed tabs. The iteration target.
- **`report`** (`content/migration-plan.html`) — the migration plan. Content contract: [`migration-plan.md`](migration-plan.md).

Both persist; they cross-link via top app-bar buttons. Regenerate either by overwriting its file.

---

## plan

Fixed structure: report header + architecture diagram + 4 tabs. Write `<div data-fill="X">…</div>` blocks; helper.js routes them into matching `[data-slot="X"]`. **Empty panes auto-hide their nav buttons.**

**The 4 tabs (in order):**

| `data-fill` slot | Tab label | What goes here |
| --- | --- | --- |
| `architecture` | Architecture | A `<script type="application/json" data-cell-model>` with the cell model (spec below). Renders as the interactive cell diagram. |
| `types` | ComponentTypes, ResourceTypes & Traits | One `<oc-rows>` per category (`ComponentTypes`, `ResourceTypes`, `Traits`), each row an `<oc-onboard>`. |
| `projects` | Projects & Components | One `<oc-rows>` per Project. Component row: name + `<ComponentType> · <exposure>` + `<oc-uses label="uses">`. Resource instances are rows too. No ports / mounts / env rebindings — those go in the Workload CRs; exceptions to *Caveats*. |
| `caveats` | Caveats | `<oc-facts>` of `<oc-fact>` items — things to know, verify, or install manually before applying. Capabilities that just need a new type / trait belong in *Types & Traits*. |

Plus two header slots:

| `data-fill` slot | Where it goes |
| --- | --- |
| `meta` | Report-header subtitle (chart name, date). |
| `nav` | Top app-bar action group. Surface a **View migration plan →** button here once the migration plan exists. |

**Skeleton:**

```html
<!-- oc-frame: plan -->

<div data-fill="meta">
  <span>{chart name + version + format}</span>
  <span class="sep">·</span>
  <span>{date}</span>
</div>

<!-- Only after writing the migration plan; omit until then. -->
<div data-fill="nav">
  <a class="btn ghost" href="/migration-plan.html">View migration plan →</a>
</div>

<div data-fill="architecture">
  <script type="application/json" data-cell-model>
  {
    "namespace": "{namespace/app name}",
    "projects": [
      {
        "name": "storefront",
        "components": [
          { "name": "frontend", "type": "web-application", "expose": "external",
            "calls": ["catalog", "payments/checkout"] },
          { "name": "catalog", "type": "service", "resources": ["catalog-db"] }
        ]
      },
      {
        "name": "payments",
        "components": [
          { "name": "checkout", "type": "service", "expose": "namespace", "calls": ["payment"] },
          { "name": "payment", "type": "worker", "external": ["payment-gateway"] }
        ]
      }
    ]
  }
  </script>
</div>
```

**The cell model** is a flat list of projects → **components**, where `components` holds **only the workloads** — the things that become OpenChoreo Components (services, web-apps, workers, scheduled-tasks). Resources and external systems are **not** components; they appear as edges (below), and the diagram draws their nodes for you. Field names mirror OpenChoreo concepts so what you put matches the CRDs; the diagram derives the cell bounds (north/south/east/west). Use plain names everywhere — never invent ids. Each component takes these optional fields:

- `type` — the workload kind that picks the node icon: `service` (default), `web-application`, `worker`, `scheduled-task` (the diagram's icon set, not a catalog lookup).
- `expose` — the broadest gateway the component is reachable from (OpenChoreo endpoint `visibility`). **Omit for most components** — they're project-only (in-cell). `"external"` → public internet (web apps, public APIs; north gateway). `"internal"` → across all namespaces in the deployment (the cluster intranet), or `"namespace"` → other projects in the same namespace (both west gateway).
- `calls` — components this one calls, as a **string array**. `"name"` = same project (in-cell link); `"project/name"` = another project **in this model** (cross-cell link). A dependency on a service **not in this import** — including another OpenChoreo project you aren't importing — goes in `external`, not `calls`; a `calls` target that isn't in the model is silently dropped (the dependency would vanish). e.g. `["catalog", "payments/checkout"]`.
- `resources` — dependencies the platform **owns and manages** as Resources (each references a ResourceType), drawn **inside the cell**. Same instances you list in the *Projects & Components* tab.
- `external` — dependencies the workload **calls out to** but the platform doesn't own, drawn on the **south egress** (outside the cell).

> **Represent each dependency exactly once.** A Resource appears only in a consumer's `resources`; an external system only in `external`; an imported Component only as its own `components` entry (consumers reach it via `calls`). Listing the same thing in two buckets double-draws it as a floating, edge-less node.
>
> **Keep all three plan surfaces consistent.** A Resource in the cell model is a Resource in *Types & Traits* and *Projects & Components* too — every ResourceType is referenced by at least one `resources` edge, and every *Projects & Components* "uses" matches a cell-model edge.
>
> **The cell model represents every dependency.** Don't thin the edges; the org view + drill-in handle density.

One project renders as a single expanded cell; multiple render as the collapsed org view (double-click a cell to drill in).

```html

<div data-fill="types">
  <!-- Three sections (ComponentTypes / ResourceTypes / Traits), same shape: <h3> + <oc-count>, then an <oc-rows> of <oc-onboard> rows. All rows are authored types. -->
  <h3>ComponentTypes <oc-count>2</oc-count></h3>
  <oc-rows>
    <oc-onboard name="web-application"><p>Renders Deployment + Service + HTTPRoute (external gateway).</p><oc-uses label="used by"><oc-use>frontend</oc-use></oc-uses></oc-onboard>
    <oc-onboard name="service"><p>Renders Deployment + Service (in-cell endpoint).</p><oc-uses label="used by"><oc-use>cartservice</oc-use><oc-use>checkoutservice</oc-use></oc-uses></oc-onboard>
  </oc-rows>

  <h3>ResourceTypes <oc-count>1</oc-count></h3>
  <oc-rows>
    <oc-onboard name="valkey"><p>Provisions a managed Redis-compatible cache; outputs <code>host</code>, <code>port</code>, <code>password</code>.</p><oc-uses label="used by"><oc-use>cartservice</oc-use></oc-uses></oc-onboard>
  </oc-rows>

  <h3>Traits <oc-count>1</oc-count></h3>
  <oc-rows>
    <oc-onboard name="probes"><p>Patches <code>livenessProbe</code> / <code>readinessProbe</code> onto the main container.</p><oc-uses label="used by"><oc-use>cartservice</oc-use><oc-use>checkoutservice</oc-use></oc-uses></oc-onboard>
  </oc-rows>
</div>

<div data-fill="projects">
  <!-- One <oc-rows> panel per Project. Component row: name + "<ComponentType> · <exposure>" + <oc-uses label="uses"> chips; Resource instances are rows too. Exposure ∈ external|internal|namespace|in-cell. Plan altitude — no ports/mounts/env rebindings (those go in the Workload CRs; exceptions to Caveats). -->
  <h3>storefront <oc-count>3</oc-count></h3>
  <oc-rows>
    <oc-onboard name="frontend"><p>web-application · <b>external</b></p></oc-onboard>
    <oc-onboard name="cartservice"><p>service · in-cell</p><oc-uses label="uses"><oc-use>redis</oc-use></oc-uses></oc-onboard>
    <oc-onboard name="redis"><p>valkey · resource</p><oc-uses label="used by"><oc-use>cartservice</oc-use></oc-uses></oc-onboard>
  </oc-rows>
</div>

<div data-fill="caveats">
  <oc-facts>
    <oc-fact kind="warn" title="{caveat title}">{plain-language explanation — inline <code> ok; bulleted <ul> / numbered <ol> bodies are styled}</oc-fact>
    …
  </oc-facts>
</div>
```

The plan is view-only — feedback comes via chat, not page events. On approval, write the migration plan to `content/migration-plan.html` (separate file) and add the nav button.

---

## report — the migration plan

Lives at `content/migration-plan.html` with `<!-- oc-frame: report -->`. Content contract: **[`migration-plan.md`](migration-plan.md)** (Prerequisites → Platform setup → Developer setup → Apply sequence). Ships **← Back to plan** and **Copy plan.md** in the top app-bar; no footer.

Content patterns available beyond the plan-tab tags:

- `<oc-callout kind="info|ok|warn|danger" label="…">` — boxed notes
- `<oc-tag kind="ok|warn|brand|danger">` — inline pills
- `dl.kv` — definition list with mono values
- `<pre><code>…</code></pre>` — code blocks (auto-attached Copy)
- `<details><summary>…</summary><div class="body">…</div></details>` — collapsibles
- `<table>` — auto-styled
- `<oc-rows>` / `<oc-onboard>` / `<oc-uses>` — reusable from the plan tabs
- `<details class="plan-preview">` — lazy-fetches `/plan.md` into a styled `<pre>`

---

## frame.html (default fallback)

When no `oc-frame` directive is present. A bare brand shell — header + main slot. Useful for an ad-hoc page (an index, a holding state, a one-off).

You write whatever fits — the same `<oc-*>` tags plus these utility classes (all from `components.css`): `.stack` `.row` `.grow` `.scroll` `.scroll-x` `.eyebrow` `.subtle` `.mute` `.mono` `.btn` (with `.primary` / `.ghost`) `.card` `.card-soft` `.badge` (with `.ok` / `.warn` / `.danger` / `.brand` / `.soft`).
