// This enhancement refreshes conversation search results without a full page reload.
addEventListener("DOMContentLoaded", () => {
  const form = document.querySelector("[data-conversation-filter]");
  if (!form) return;
  form.addEventListener("submit", async (event) => {
    event.preventDefault();
    const url = new URL(form.action, location.origin);
    url.search = new URLSearchParams(new FormData(form));
    const response = await fetch(url, { headers: { "X-Audit-Fragment": "conversations" } });
    if (!response.ok) return;
    document.querySelector("#conversation-results").innerHTML = await response.text();
    history.replaceState(null, "", url);
  });
});
