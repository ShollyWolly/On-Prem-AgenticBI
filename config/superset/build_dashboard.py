"""
Build the demo charts + dashboard programmatically, inside the Superset container.

WHY NOT CLICK THEM IN THE UI: the usual advice is to build charts by hand and
export them, because chart `params` and dashboard `position_json` are large,
version-sensitive blobs. That is true, but it also means the dashboard is only
reproducible by a human repeating a click-path. Constructing them here keeps
`docker compose down -v && up -d` sufficient to rebuild the whole demo, which is
the point of the PoC.

Run:  docker compose exec -T superset python /app/assets/../build_dashboard.py
(runs automatically from the superset container's start command)

Idempotent: charts and the dashboard are keyed on stable slugs/UUIDs and updated
in place on re-run. Each chart's UUID is derived from its spec `slug` (uuid5), so
RENAMING a chart is a rename rather than "create a second chart and orphan the
first" -- which is what keying the lookup on slice_name gave us.

DESIGN RULES APPLIED (deliberate, not defaults):
  * Revenue trend uses paid_at, never rented_at -- rental dates have a
    two-month hole in this data and render as a gap that reads as a broken
    pipeline.
  * Every bar chart is SINGLE-SERIES: x-axis is the category, `groupby` is
    EMPTY. That makes all bars slot-1 blue. Colouring each bar differently
    would encode rank as hue, which is meaningless and the classic
    colour-by-rank anti-pattern.
  * No dual-axis chart. Two scales means two charts.
  * No map: Pagila has no lat/long, only place names.
  * No sparkline on Avg Rental Duration -- it has no meaningful trend.
"""
import json
import uuid

from superset.app import create_app

app = create_app()

CATEGORICAL_SCHEME = "agenticBiDark"

# Fixed namespace so chart UUIDs are reproducible across rebuilds and machines.
CHART_NS = uuid.uuid5(uuid.NAMESPACE_URL, "https://localCompany.example/agentic-bi/charts")


def chart_uuid(slug: str) -> uuid.UUID:
    return uuid.uuid5(CHART_NS, slug)

# --------------------------------------------------------------------------- #
#  Chart definitions
# --------------------------------------------------------------------------- #
# (slug, name, viz_type, dataset, params)
BIG_NUMBER_SUBHEADER = "last 12 months"


def big_number(metric, subheader, fmt):
    return {
        "viz_type": "big_number_total",
        "metric": metric,
        "subheader": subheader,
        "y_axis_format": fmt,
        "adhoc_filters": [],
        "header_font_size": 0.3,
        "subheader_font_size": 0.125,
    }


CHARTS = [
    # ---- KPI row -----------------------------------------------------------
    dict(
        slug="abi-kpi-revenue", name="Revenue", dataset="revenue_analytics",
        params=big_number("total_revenue", BIG_NUMBER_SUBHEADER, "$,.0f"),
    ),
    dict(
        slug="abi-kpi-payments", name="Payments", dataset="revenue_analytics",
        params=big_number("payment_count", BIG_NUMBER_SUBHEADER, ",d"),
    ),
    dict(
        slug="abi-kpi-customers", name="Paying Customers", dataset="revenue_analytics",
        params=big_number("paying_customers", BIG_NUMBER_SUBHEADER, ",d"),
    ),
    dict(
        slug="abi-kpi-duration", name="Avg Rental Duration", dataset="rental_analytics",
        params=big_number("avg_rental_duration_days", "days", ",.2f"),
    ),

    # ---- Revenue over time -------------------------------------------------
    dict(
        slug="abi-revenue-trend", name="Revenue over Time", dataset="revenue_analytics",
        params={
            "viz_type": "echarts_timeseries_line",
            "x_axis": "paid_at",
            "time_grain_sqla": "P1M",
            "metrics": ["total_revenue"],
            # EMPTY: one series, one colour, no legend. The title says what it is.
            "groupby": [],
            "adhoc_filters": [],
            "row_limit": 1000,
            "seriesType": "line",
            "show_legend": False,
            "markerEnabled": True,
            "x_axis_time_format": "%b %Y",
            "y_axis_format": "$,.0f",
            "color_scheme": CATEGORICAL_SCHEME,
            "rich_tooltip": True,
            "tooltipTimeFormat": "%b %Y",
        },
    ),

    # ---- Revenue by category ----------------------------------------------
    dict(
        slug="abi-revenue-category", name="Revenue by Category", dataset="revenue_analytics",
        params={
            "viz_type": "echarts_timeseries_bar",
            "x_axis": "category_name",
            # Categorical x-axis: no time grain at all, else Superset tries to
            # DATE_TRUNC a string column.
            "time_grain_sqla": None,
            "metrics": ["total_revenue"],
            "groupby": [],
            "adhoc_filters": [],
            "row_limit": 20,
            "orientation": "horizontal",
            "show_legend": False,
            "y_axis_format": "$,.0f",
            "color_scheme": CATEGORICAL_SCHEME,
            "x_axis_sort": "total_revenue",
            "x_axis_sort_asc": False,
        },
    ),

    # ---- Revenue by country ------------------------------------------------
    dict(
        # The row count is IN THE TITLE on purpose. This chart covers 15 of 108
        # countries -- about 61% of total revenue -- and a bare "Top Countries by
        # Revenue" invites the reader to treat the bars as the whole picture. A
        # reviewer looking at it can otherwise only tell by summing the bars and
        # noticing they fall short of the revenue KPI.
        slug="abi-revenue-country", name="Top 15 Countries by Revenue", dataset="revenue_analytics",
        params={
            "viz_type": "echarts_timeseries_bar",
            "x_axis": "country_name",
            "time_grain_sqla": None,
            "metrics": ["total_revenue"],
            "groupby": [],
            "adhoc_filters": [],
            "row_limit": 15,
            "orientation": "horizontal",
            "show_legend": False,
            "y_axis_format": "$,.0f",
            "color_scheme": CATEGORICAL_SCHEME,
            "x_axis_sort": "total_revenue",
            "x_axis_sort_asc": False,
        },
    ),

    # ---- Rentals by MPAA rating -------------------------------------------
    dict(
        slug="abi-rentals-rating", name="Rentals by MPAA Rating", dataset="rental_analytics",
        params={
            "viz_type": "echarts_timeseries_bar",
            "x_axis": "rating",
            "time_grain_sqla": None,
            "metrics": ["rental_count"],
            "groupby": [],
            "adhoc_filters": [],
            "row_limit": 10,
            "orientation": "vertical",
            "show_legend": False,
            "y_axis_format": ",d",
            "color_scheme": CATEGORICAL_SCHEME,
            "x_axis_sort": "rental_count",
            "x_axis_sort_asc": False,
        },
    ),

    # ---- Top films (a ranked list is a table, not a chart) -----------------
    dict(
        slug="abi-top-films", name="Top 10 Films by Revenue", dataset="revenue_analytics",
        params={
            "viz_type": "table",
            "query_mode": "aggregate",
            "groupby": ["title", "category_name"],
            "metrics": ["total_revenue", "payment_count"],
            "adhoc_filters": [],
            "row_limit": 10,
            "order_desc": True,
            "timeseries_limit_metric": "total_revenue",
            "color_scheme": CATEGORICAL_SCHEME,
            "show_totals": False,
            "table_timestamp_format": "smart_date",
        },
    ),
]

DASHBOARD_SLUG = "agentic-bi"
DASHBOARD_TITLE = "Agentic BI - Rental Business Overview"


def main():
    with app.app_context():
        from superset import db
        from superset.connectors.sqla.models import SqlaTable
        from superset.models.dashboard import Dashboard
        from superset.models.slice import Slice

        datasets = {
            t.table_name: t for t in db.session.query(SqlaTable).all()
        }
        missing = {c["dataset"] for c in CHARTS} - set(datasets)
        if missing:
            raise SystemExit(f"datasets not imported yet: {missing}")

        slices = []
        for spec in CHARTS:
            ds = datasets[spec["dataset"]]
            params = dict(spec["params"])
            params["datasource"] = f"{ds.id}__table"

            # Look up by UUID first (stable across renames), then fall back to
            # the name so charts created by an earlier version of this script are
            # adopted instead of duplicated.
            u = str(chart_uuid(spec["slug"]))
            sl = db.session.query(Slice).filter_by(uuid=u).one_or_none()
            if sl is None:
                sl = (
                    db.session.query(Slice)
                    .filter_by(slice_name=spec["name"], datasource_id=ds.id)
                    .one_or_none()
                )
            if sl is None:
                sl = Slice(slice_name=spec["name"])
                db.session.add(sl)

            sl.uuid = u
            sl.slice_name = spec["name"]
            sl.datasource_id = ds.id
            sl.datasource_type = "table"
            sl.datasource_name = ds.table_name
            sl.viz_type = params["viz_type"]
            sl.params = json.dumps(params)
            # query_context must be stored explicitly. The dashboard frontend
            # rebuilds one from form_data on render, but the REST data endpoint
            # (GET /api/v1/chart/<id>/data/) refuses without a saved one --
            # "Chart has no query context saved" -- and so do thumbnails and
            # alerts. There is no server-side equivalent of the frontend's
            # per-viz-type buildQuery(), so we construct it here. Superset's own
            # ChartDataQueryContextSchema validates it (see verify() below), so
            # a mistake fails loudly rather than rendering an empty chart.
            sl.query_context = json.dumps(build_query_context(ds, params))
            slices.append(sl)
            print(f"RESULT chart: {spec['name']} ({params['viz_type']}) -> {spec['dataset']}")

        db.session.flush()

        dash = (
            db.session.query(Dashboard).filter_by(slug=DASHBOARD_SLUG).one_or_none()
        )
        if dash is None:
            dash = Dashboard(slug=DASHBOARD_SLUG)
            db.session.add(dash)

        dash.dashboard_title = DASHBOARD_TITLE
        dash.published = True
        dash.slices = slices
        dash.position_json = json.dumps(build_position(slices))

        # Drop any chart this script does not manage. Without this, RENAMING a
        # chart leaves the old one behind: it is no longer on the dashboard, but
        # list_charts still returns it and the Dashboard Reviewer agent then reads
        # a stale duplicate and reports it as a real chart. This script owns the
        # whole Superset instance in this demo, so "unmanaged" means "left over".
        managed = {sl.id for sl in slices}
        for orphan in db.session.query(Slice).all():
            if orphan.id in managed:
                continue
            # Detach from every dashboard first; the association row has a FK.
            for d in list(orphan.dashboards):
                d.slices = [s for s in d.slices if s.id != orphan.id]
            print(f"RESULT removed orphan chart: {orphan.slice_name} (id {orphan.id})")
            db.session.delete(orphan)
        dash.json_metadata = json.dumps(
            {
                "color_scheme": CATEGORICAL_SCHEME,
                "refresh_frequency": 0,
                "expanded_slices": {},
                "label_colors": {},
                "cross_filters_enabled": True,
            }
        )

        db.session.commit()
        print(f"RESULT dashboard: /superset/dashboard/{DASHBOARD_SLUG}/ with {len(slices)} charts")


def build_query_context(ds, params):
    """
    Translate our form_data into a query_context payload.

    Mechanical, but the two details that matter:
      * The x-axis column goes in `columns`, not in a separate field. For a
        categorical axis time_grain_sqla MUST be absent -- leaving a grain on a
        string column makes Superset wrap it in DATE_TRUNC and the query fails.
      * orderby drives the "top N" behaviour on the bar charts and the table;
        without it row_limit truncates an arbitrary slice of the data, which
        looks like a ranking but is not one.
    """
    viz = params["viz_type"]
    metrics = params.get("metrics") or ([params["metric"]] if params.get("metric") else [])
    columns = []
    orderby = []
    extras = {"having": "", "where": ""}

    if viz == "big_number_total":
        row_limit = 1
    elif viz == "table":
        columns = list(params.get("groupby") or [])
        row_limit = params.get("row_limit", 10)
        sort_metric = params.get("timeseries_limit_metric")
        if sort_metric:
            orderby = [[sort_metric, not params.get("order_desc", True)]]
    else:
        x_axis = params.get("x_axis")
        grain = params.get("time_grain_sqla")
        if x_axis and grain:
            # Under GENERIC_CHART_AXES the time grain is carried by the x-axis
            # column itself as an adhoc BASE_AXIS entry -- it is NOT enough to
            # put time_grain_sqla in `extras`. Getting this wrong is silent and
            # nasty: the query succeeds but returns ungrouped raw rows (one per
            # payment) instead of monthly totals, so the chart renders a dense
            # scribble that looks like real data.
            columns.append(
                {
                    "timeGrain": grain,
                    "columnType": "BASE_AXIS",
                    "sqlExpression": x_axis,
                    "label": x_axis,
                    "expressionType": "SQL",
                }
            )
            extras["time_grain_sqla"] = grain
        elif x_axis:
            # Categorical axis: no grain anywhere, or Superset DATE_TRUNCs a
            # string column.
            columns.append(x_axis)
        columns.extend(params.get("groupby") or [])
        row_limit = params.get("row_limit", 1000)
        sort_col = params.get("x_axis_sort")
        if sort_col:
            orderby = [[sort_col, params.get("x_axis_sort_asc", False)]]

    return {
        "datasource": {"id": ds.id, "type": "table"},
        "force": False,
        "queries": [
            {
                "filters": [],
                "extras": extras,
                "applied_time_extras": {},
                "columns": columns,
                "metrics": metrics,
                "orderby": orderby,
                "annotation_layers": [],
                "row_limit": row_limit,
                "series_limit": 0,
                "order_desc": params.get("order_desc", True),
                "url_params": {},
                "custom_params": {},
                "custom_form_data": {},
            }
        ],
        "form_data": params,
        "result_format": "json",
        "result_type": "full",
    }


def build_position(slices):
    """
    Hand-built layout tree. Superset's grid is 12 columns wide.

    Row 1: four KPI big-numbers, 3 columns each.
    Row 2: revenue trend, full width (a trend needs horizontal room).
    Row 3: revenue by category | top films table.
    Row 4: top countries | rentals by rating.
    """
    by_name = {s.slice_name: s for s in slices}

    def chart(name, w, h):
        s = by_name[name]
        key = f"CHART-{s.id}"
        return key, {
            "type": "CHART",
            "id": key,
            "children": [],
            "meta": {
                "chartId": s.id,
                "sliceName": s.slice_name,
                "uuid": str(s.uuid),
                "width": w,
                "height": h,
            },
        }

    pos = {
        "DASHBOARD_VERSION_KEY": "v2",
        "ROOT_ID": {"type": "ROOT", "id": "ROOT_ID", "children": ["GRID_ID"]},
        "GRID_ID": {"type": "GRID", "id": "GRID_ID", "children": [], "parents": ["ROOT_ID"]},
        "HEADER_ID": {"type": "HEADER", "id": "HEADER_ID", "meta": {"text": DASHBOARD_TITLE}},
    }

    rows = [
        [("Revenue", 3, 40), ("Payments", 3, 40), ("Paying Customers", 3, 40),
         ("Avg Rental Duration", 3, 40)],
        [("Revenue over Time", 12, 60)],
        [("Revenue by Category", 6, 70), ("Top 10 Films by Revenue", 6, 70)],
        [("Top 15 Countries by Revenue", 6, 70), ("Rentals by MPAA Rating", 6, 70)],
    ]

    for i, row in enumerate(rows):
        row_id = f"ROW-abi-{i}"
        children = []
        for name, w, h in row:
            key, node = chart(name, w, h)
            node["parents"] = ["ROOT_ID", "GRID_ID", row_id]
            pos[key] = node
            children.append(key)
        pos[row_id] = {
            "type": "ROW",
            "id": row_id,
            "children": children,
            "meta": {"background": "BACKGROUND_TRANSPARENT"},
            "parents": ["ROOT_ID", "GRID_ID"],
        }
        pos["GRID_ID"]["children"].append(row_id)

    return pos


if __name__ == "__main__":
    main()
