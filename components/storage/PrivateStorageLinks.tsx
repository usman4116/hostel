"use client";

import { useEffect, useState } from "react";
import { supabase } from "@/lib/supabase";

export default function PrivateStorageLinks({ title, bucket, references }: { title: string; bucket: string; references: string[] }) {
  const [urls, setUrls] = useState<string[]>([]);
  useEffect(() => {
    let active = true;
    void Promise.all(references.map(async (reference) => {
      if (/^https?:\/\//i.test(reference)) return reference;
      const result = await supabase.storage.from(bucket).createSignedUrl(reference, 300);
      return result.data?.signedUrl ?? "";
    })).then((resolved) => { if (active) setUrls(resolved); });
    return () => { active = false; };
  }, [bucket, references.join("\u0000")]);
  if (!references.length) return null;
  return <div className="mt-3 flex flex-wrap items-center gap-2"><span className="text-xs font-semibold text-slate-500">{title}:</span>{urls.map((url, index) => url ? <a key={`${url}-${index}`} href={url} target="_blank" rel="noreferrer" className="rounded-lg border px-3 py-1.5 text-xs font-semibold text-indigo-700">Photo {index + 1}</a> : null)}</div>;
}
