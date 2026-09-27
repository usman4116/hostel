"use client";

import { useState } from "react";
import Link from "next/link";
import { supabase } from "@/lib/supabase";
import { provisionRoomBeds } from "@/lib/bedProvisioning";

export default function AddRoomPage() {
  const [roomNumber, setRoomNumber] = useState("");
  const [floor, setFloor] = useState("");
  const [capacity, setCapacity] = useState("");
  const [monthlyRent, setMonthlyRent] = useState("");
  const [roomType, setRoomType] = useState("Shared");
  const [status, setStatus] = useState("Available");
  const [notes, setNotes] = useState("");
  const [saving, setSaving] = useState(false);
  const [message, setMessage] = useState("");
  const [error, setError] = useState("");

  const handleSubmit = async () => {
    setSaving(true);
    setMessage("");
    setError("");

    const parsedCapacity = Number(capacity);
    if (!roomNumber.trim() || !Number.isInteger(parsedCapacity) || parsedCapacity <= 0) {
      setError("Room number and a valid capacity are required.");
      setSaving(false);
      return;
    }

    const parsedFloorNumber =
      floor && /^-?\d+$/.test(floor.trim()) ? parseInt(floor.trim(), 10) : null;

    const { data: room, error: roomError } = await supabase
      .from("rooms")
      .insert({
        room_number: roomNumber.trim(),
        floor_number: parsedFloorNumber,
        total_beds: parsedCapacity,
        monthly_rent: Number(monthlyRent) || 0,
        room_type: roomType || "Shared",
        status: status || "Available",
        description: notes.trim() || null,
      })
      .select("id")
      .single();

    if (roomError || !room) {
      setError(roomError?.message ?? "Room could not be saved.");
      setSaving(false);
      return;
    }

    if ((status || "Available") !== "Inactive") {
      const provisionResult = await provisionRoomBeds({
        roomId: String(room.id),
        capacity: parsedCapacity,
        existingBedNumbers: [],
      });

      if (provisionResult.errors.length > 0) {
        setError(
          `Room saved, but only ${provisionResult.created} of ${provisionResult.requested} beds were created. Open Rooms & Beds to review and retry.`,
        );
      } else {
        setMessage(
          `Room saved successfully with ${provisionResult.created} vacant bed${
            provisionResult.created === 1 ? "" : "s"
          }.`,
        );
      }
    } else {
      setMessage("Inactive room saved. No beds were created.");
    }

    setSaving(false);
  };

  return (
    <main className="min-h-screen bg-gray-100 p-4 sm:p-6 lg:p-10">
      <section className="mx-auto max-w-4xl">
        {/* Header */}
        <div className="mb-6 sm:mb-8">
          <h1 className="text-2xl font-bold sm:text-4xl">Add Room</h1>
          <p className="mt-1 text-sm text-gray-600 sm:mt-2 sm:text-base">
            Create a new hostel room
          </p>
        </div>

        {/* Form */}
        <div className="rounded-2xl bg-white p-4 shadow-lg sm:p-8">
          {(message || error) && (
            <div
              className={`mb-6 rounded-xl border px-4 py-3 text-sm font-medium ${
                error
                  ? "border-red-200 bg-red-50 text-red-700"
                  : "border-emerald-200 bg-emerald-50 text-emerald-700"
              }`}
            >
              {error || message}
            </div>
          )}

          <h2 className="mb-6 text-xl font-bold sm:text-2xl">Room Information</h2>

          <div className="grid gap-4 sm:gap-6 md:grid-cols-2">
            <div>
              <label className="mb-2 block font-medium">Room Number</label>
              <input
                type="text"
                placeholder="Room 101"
                className="w-full rounded-xl border p-3"
                value={roomNumber}
                onChange={(e) => setRoomNumber(e.target.value)}
              />
            </div>

            <div>
              <label className="mb-2 block font-medium">Floor</label>
              <select
                className="w-full rounded-xl border p-3"
                value={floor}
                onChange={(e) => setFloor(e.target.value)}
              >
                <option>Ground Floor</option>
                <option>First Floor</option>
                <option>Second Floor</option>
                <option>Third Floor</option>
              </select>
            </div>

            <div>
              <label className="mb-2 block font-medium">Capacity</label>
              <input
                type="number"
                placeholder="4"
                className="w-full rounded-xl border p-3"
                value={capacity}
                onChange={(e) => setCapacity(e.target.value)}
              />
            </div>

            <div>
              <label className="mb-2 block font-medium">Monthly Rent</label>
              <input
                type="number"
                placeholder="15000"
                className="w-full rounded-xl border p-3"
                value={monthlyRent}
                onChange={(e) => setMonthlyRent(e.target.value)}
              />
            </div>

            <div>
              <label className="mb-2 block font-medium">Room Type</label>
              <select
                className="w-full rounded-xl border p-3"
                value={roomType}
                onChange={(event) => setRoomType(event.target.value)}
              >
                <option>Single</option>
                <option>Double</option>
                <option>Triple</option>
                <option>Shared</option>
              </select>
            </div>

            <div>
              <label className="mb-2 block font-medium">Status</label>
              <select
                className="w-full rounded-xl border p-3"
                value={status}
                onChange={(event) => setStatus(event.target.value)}
              >
                <option>Available</option>
                <option>Occupied</option>
                <option>Maintenance</option>
                <option>Inactive</option>
              </select>
            </div>

            <div className="md:col-span-2">
              <label className="mb-2 block font-medium">Notes</label>
              <textarea
                rows={4}
                placeholder="Room notes..."
                className="w-full rounded-xl border p-3"
                value={notes}
                onChange={(event) => setNotes(event.target.value)}
              ></textarea>
            </div>
          </div>

          <div className="mt-8 flex flex-col gap-3 sm:mt-10 sm:flex-row sm:gap-4">
            <button
              type="button"
              onClick={handleSubmit}
              disabled={saving}
              className="rounded-xl bg-blue-600 px-8 py-3 text-center font-semibold text-white hover:bg-blue-700"
            >
              {saving ? "Saving..." : "Save Room"}
            </button>

            <Link
              href="/rooms"
              className="rounded-xl border px-8 py-3 text-center font-semibold hover:bg-gray-100"
            >
              Cancel
            </Link>
          </div>
        </div>
      </section>
    </main>
  );
}
