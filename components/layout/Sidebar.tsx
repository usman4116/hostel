"use client";

import { normalizeIdentityEmail } from "@/lib/identity";


import Link from "next/link";
import { usePathname, useSearchParams } from "next/navigation";
import { Suspense, useEffect, useState } from "react";
import ProfileDropdown from "@/components/layout/ProfileDropdown";
import { isSuperAdmin } from "@/lib/permissions";
import { supabase } from "@/lib/supabase";

const menuItems = [
  { name: "Dashboard", href: "/dashboard", permissionId: "dashboard" },
  { name: "Admissions", href: "/admissions", permissionId: "admissions" },
  { name: "Residents", href: "/residents", permissionId: "residents" },
  { name: "Rooms", href: "/rooms", permissionId: "rooms" },
  { name: "Beds", href: "/beds", permissionId: "beds" },
  { name: "Payments", href: "/payments", permissionId: "payments" },
  { name: "Rent Bills", href: "/billing?type=Rent", permissionId: "rent_bills" },
  { name: "Meter Reading", href: "/meter-reading", permissionId: "meter_reading" },
  { name: "Security Deposits", href: "/billing?type=Security Deposit", permissionId: "security_deposits" },
  { name: "Contracts", href: "/contracts", permissionId: "contracts" },
  { name: "Inspections", href: "/inspection", permissionId: "inspections" },
  { name: "Maintenance", href: "/maintenance", permissionId: "maintenance" },
  { name: "Notices", href: "/notices", permissionId: "notices" },
  { name: "Reports", href: "/reports", permissionId: "reports" },
  { name: "Settings", href: "/settings", permissionId: "settings" },
];

function SidebarContent() {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [showAdminTools, setShowAdminTools] = useState(false);
  const [allowedPermissionIds, setAllowedPermissionIds] = useState<string[] | null>(null);
  const [isSuper, setIsSuper] = useState(false);
  const [mobileOpen, setMobileOpen] = useState(false);

  useEffect(() => {
    let active = true;

    async function loadAdminAccess() {
      const { data: authData } = await supabase.auth.getUser();
      const email = authData.user?.email;
      if (!email) return;

      const { data } = await supabase
        .from("staff_users")
        .select("role, status, permissions")
        .eq("email", normalizeIdentityEmail(email))
        .maybeSingle();

      if (!active) return;

      const superAdminUser = isSuperAdmin(data?.role);
      setIsSuper(superAdminUser);

      const rawPerms = data?.permissions;
      const userPerms: string[] = Array.isArray(rawPerms)
        ? rawPerms
        : typeof rawPerms === "string"
        ? JSON.parse(rawPerms || "[]")
        : [];

      setAllowedPermissionIds(userPerms);

      const canAccessAdmin = superAdminUser || userPerms.includes("admin_tools");
      setShowAdminTools(canAccessAdmin);
    }

    void loadAdminAccess();
    return () => {
      active = false;
    };
  }, []);

  useEffect(() => {
    if (!mobileOpen) return;

    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") setMobileOpen(false);
    }

    document.addEventListener("keydown", onKeyDown);
    const previousOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKeyDown);
      document.body.style.overflow = previousOverflow;
    };
  }, [mobileOpen]);

  function isActive(href: string) {
    if (href === "/billing?type=Security Deposit") {
      return pathname === "/billing" && searchParams.get("type") === "Security Deposit";
    }
    if (href === "/billing?type=Rent" || href === "/billing") {
      return pathname === "/billing" && searchParams.get("type") !== "Security Deposit";
    }

    const matchesRoute = pathname === href || pathname.startsWith(`${href}/`);

    if (href === "/payments") {
      return (
        matchesRoute ||
        pathname === "/payment-verification" ||
        pathname.startsWith("/payment-verification/")
      );
    }

    return matchesRoute;
  }

  const visibleMenuItems = menuItems.filter((item) => {
    if (allowedPermissionIds === null) return true;
    if (isSuper) return true;
    return allowedPermissionIds.includes(item.permissionId);
  });

  const navLinks = (
    <nav className="mt-8 space-y-1.5 lg:mt-10 lg:space-y-2">
      {visibleMenuItems.map((item) => (
        <Link
          key={item.href}
          href={item.href}
          onClick={() => setMobileOpen(false)}
          className={`block rounded-lg p-3 text-sm font-medium transition lg:text-base ${
            isActive(item.href)
              ? "bg-blue-600 text-white"
              : "text-slate-200 hover:bg-slate-800 hover:text-white dark:hover:bg-slate-900"
          }`}
        >
          {item.name}
        </Link>
      ))}
      {showAdminTools && (
        <Link
          href="/dashboard/settings/data-management"
          onClick={() => setMobileOpen(false)}
          className={`flex items-center gap-3 rounded-lg p-3 text-sm font-medium transition lg:text-base ${
            isActive("/dashboard/settings/data-management")
              ? "bg-blue-600 text-white"
              : "text-slate-200 hover:bg-slate-800 hover:text-white dark:hover:bg-slate-900"
          }`}
        >
          <AdminToolsIcon />
          <span>Admin Tools</span>
        </Link>
      )}
    </nav>
  );

  return (
    <>
      {/* Mobile Sticky Top Header */}
      <div className="sticky top-0 z-40 flex items-center justify-between gap-3 border-b border-slate-800 bg-slate-900 px-4 py-3 text-slate-100 shadow-sm lg:hidden">
        <div className="flex min-w-0 items-center gap-3">
          <button
            type="button"
            aria-label="Open navigation menu"
            aria-expanded={mobileOpen}
            onClick={() => setMobileOpen(true)}
            className="flex h-10 w-10 shrink-0 items-center justify-center rounded-xl border border-slate-700 bg-slate-800 text-slate-100 transition hover:bg-slate-700 focus:outline-none focus:ring-2 focus:ring-blue-400"
          >
            <svg className="h-5 w-5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
              <path strokeLinecap="round" strokeLinejoin="round" d="M4 6h16M4 12h16M4 18h16" />
            </svg>
          </button>
          <Link href="/dashboard" className="flex min-w-0 items-center gap-2.5">
            <img src="/logo.jpg" alt="Logo" className="h-9 w-9 shrink-0 rounded-full bg-white object-cover" />
            <span className="truncate text-sm font-bold leading-tight text-blue-400 sm:text-base">
              University Girls Hostel
            </span>
          </Link>
        </div>
        <ProfileDropdown />
      </div>

      {/* Mobile Slide-Over Drawer */}
      {mobileOpen && (
        <div className="fixed inset-0 z-50 flex lg:hidden" role="dialog" aria-modal="true" aria-label="Navigation menu">
          <div
            className="fixed inset-0 bg-slate-950/60 backdrop-blur-xs"
            onClick={() => setMobileOpen(false)}
            aria-hidden="true"
          />
          <aside className="relative z-10 flex h-full w-72 max-w-[82vw] flex-col overflow-y-auto bg-slate-900 p-5 text-slate-100 shadow-2xl dark:bg-slate-950">
            <div className="flex items-center justify-between gap-3">
              <Link
                href="/dashboard"
                onClick={() => setMobileOpen(false)}
                className="flex min-w-0 items-center gap-3 rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-400"
              >
                <img src="/logo.jpg" alt="Logo" className="h-10 w-10 shrink-0 rounded-full bg-white object-cover" />
                <span className="text-base font-bold leading-tight text-blue-400">
                  University Girls<br />Hostel
                </span>
              </Link>
              <button
                type="button"
                aria-label="Close navigation menu"
                onClick={() => setMobileOpen(false)}
                className="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl border border-slate-700 bg-slate-800 text-lg text-slate-300 transition hover:bg-slate-700 hover:text-white"
              >
                ✕
              </button>
            </div>
            {navLinks}
          </aside>
        </div>
      )}

      {/* Desktop Sidebar */}
      <aside className="hidden min-h-screen w-72 shrink-0 flex-col bg-slate-900 p-6 text-slate-100 lg:flex dark:bg-slate-950">
        <Link
          href="/dashboard"
          className="block rounded-lg focus:outline-none focus:ring-2 focus:ring-blue-400 focus:ring-offset-2 focus:ring-offset-slate-900"
        >
          <div className="flex items-center gap-3">
            <img src="/logo.jpg" alt="Logo" className="w-12 h-12 rounded-full object-cover bg-white" />
            <h1 className="text-xl font-bold text-blue-400 leading-tight">University Girls<br/>Hostel</h1>
          </div>
        </Link>

        {navLinks}
      </aside>
    </>
  );
}

export default function Sidebar() {
  return (
    <Suspense
      fallback={
        <>
          <div className="h-16 w-full bg-slate-900 lg:hidden" />
          <aside className="hidden min-h-screen w-72 shrink-0 flex-col bg-slate-900 p-6 text-slate-100 lg:flex dark:bg-slate-950" />
        </>
      }
    >
      <SidebarContent />
    </Suspense>
  );
}

function AdminToolsIcon() {
  return (
    <svg className="h-5 w-5 shrink-0" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" aria-hidden="true">
      <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10Z" />
      <path d="M9 12h6M12 9v6" />
    </svg>
  );
}
