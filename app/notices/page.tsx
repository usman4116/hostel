"use client";
import Link from "next/link";
import { useCallback, useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";
import { NOTICE_AUDIENCES, NOTICE_STATUSES, bigintId, noticePublicationError, type NoticeAudience, type NoticeStatus } from "@/lib/canonical";

type Notice = { id: string | number; title: string; description: string; audience: NoticeAudience; status: NoticeStatus; publish_date: string | null; expiry_date: string | null; pinned: boolean; show_as_popup: boolean; updated_at: string };
export default function NoticesPage() {
  const [notices, setNotices] = useState<Notice[]>([]);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState("");
  const [audience, setAudience] = useState("All");
  const [status, setStatus] = useState("Current");
  const refresh = useCallback(async () => {
    setLoading(true);
    const result = await supabase.from("notices").select("id::text,title,description,audience,status,publish_date,expiry_date,pinned,show_as_popup,updated_at").order("pinned", { ascending: false }).order("publish_date", { ascending: false });
    if (result.error) setError("Notices could not be loaded.");
    else setNotices((result.data ?? []) as Notice[]);
    setLoading(false);
  }, []);
  useEffect(() => { const timer = setTimeout(() => void refresh(), 0); return () => clearTimeout(timer); }, [refresh]);
  async function changeStatus(notice: Notice, next: NoticeStatus) {
    if (notice.status === "Archived" || !window.confirm(next + ' notice "' + notice.title + '"?')) return;
    const publishDate = next === "Published" ? notice.publish_date || new Date().toISOString().slice(0, 10) : notice.publish_date;
    const validation = noticePublicationError(next, publishDate, notice.expiry_date);
    if (validation) { setError(validation); return; }
    setError("");
    if (next === "Published" && notice.audience === "Selected Residents") {
      const recipients = await supabase.from("notice_recipients").select("resident_id").eq("notice_id", bigintId(notice.id)).limit(1);
      if (recipients.error || !recipients.data?.length) { setError("Save selected recipients before publishing this notice."); return; }
    }
    const result = await supabase.from("notices").update({ status: next, publish_date: publishDate })
      .eq("id", bigintId(notice.id)).eq("status", notice.status).eq("updated_at", notice.updated_at).select("id::text").maybeSingle();
    if (result.error || !result.data) { setError("Notice changed or could not be saved. Refresh before retrying."); return; }
    await refresh();
  }
  const visible = notices.filter(notice => (audience === "All" || notice.audience === audience) &&
    (status === "All" || (status === "Current" ? notice.status !== "Archived" : notice.status === status)) &&
    (notice.title + " " + notice.description).toLowerCase().includes(search.trim().toLowerCase()));
  return <main className="min-h-screen bg-slate-50 p-4 sm:p-6"><div className="mx-auto max-w-6xl space-y-6">
    <header className="flex flex-wrap items-center justify-between gap-3"><h1 className="text-2xl font-bold sm:text-3xl">Notices</h1><Link className="rounded-xl bg-indigo-600 px-5 py-3 text-sm font-semibold text-white" href="/dashboard/notices/add">Add Notice</Link></header>
    {error && <p role="alert" className="text-red-700">{error}</p>}
    <div className="flex flex-wrap gap-3 sm:gap-4">
      <input aria-label="Search notices" className="w-full rounded border p-3 sm:w-auto" value={search} onChange={event => setSearch(event.target.value)} placeholder="Search notices" />
      <select aria-label="Audience" className="w-full rounded border p-3 sm:w-auto" value={audience} onChange={event => setAudience(event.target.value)}>{["All", ...NOTICE_AUDIENCES].map(value => <option key={value}>{value}</option>)}</select>
      <select aria-label="Status" className="w-full rounded border p-3 sm:w-auto" value={status} onChange={event => setStatus(event.target.value)}>{["Current", "All", ...NOTICE_STATUSES].map(value => <option key={value}>{value}</option>)}</select>
    </div>
    {loading ? <p>Loading notices...</p> : visible.length === 0 ? <p>No notices found.</p> : visible.map(notice => <article key={String(notice.id)} className="rounded-2xl border bg-white p-4 sm:p-6">
      <h2 className="text-xl font-bold">{notice.title}</h2><p className="my-2 text-sm">{notice.status} ? {notice.audience}{notice.pinned ? " ? Pinned" : ""}{notice.show_as_popup ? " ? Popup" : ""}</p>
      <p className="whitespace-pre-wrap">{notice.description}</p><p className="my-3 text-sm">Published: {notice.publish_date || "Not scheduled"} ? Expires: {notice.expiry_date || "No expiry"}</p>
      <div className="flex flex-wrap gap-4"><Link className="text-indigo-700 underline" href={"/notices/" + bigintId(notice.id)}>View</Link>
      {notice.status !== "Archived" && <><Link className="text-indigo-700 underline" href={"/dashboard/notices/edit/" + bigintId(notice.id)}>Edit</Link>
        <button onClick={() => void changeStatus(notice, notice.status === "Published" ? "Draft" : "Published")}>{notice.status === "Published" ? "Unpublish" : "Publish"}</button>
        <button onClick={() => void changeStatus(notice, "Archived")}>Archive</button></>}
      </div></article>)}
  </div></main>;
}
