import { createClient } from "@supabase/supabase-js";

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
const supabaseServiceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!supabaseUrl || !supabaseServiceRoleKey) {
  console.error("Missing NEXT_PUBLIC_SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY");
  process.exit(1);
}

const sb = createClient(supabaseUrl, supabaseServiceRoleKey);

const seedRooms = [
  // Ground Floor (floor_number: 0) - Rooms 1 to 8
  ...Array.from({ length: 8 }, (_, i) => ({
    room_number: String(i + 1),
    floor_number: 0,
    block_name: "Main Building",
    room_type: "2 Sharing",
    total_beds: 2,
    monthly_rent: 17000,
    security_deposit_amount: 17000,
    has_ac: false,
    has_attached_bathroom: true,
    has_balcony: false,
    description: "Ground Floor - 2 Sharing (PKR 17,000/seat)",
  })),
  // 1st Floor (floor_number: 1) - Rooms 9 to 16 + Single Economy + Single Deluxe
  ...Array.from({ length: 8 }, (_, i) => ({
    room_number: String(i + 9),
    floor_number: 1,
    block_name: "Main Building",
    room_type: "2 Sharing",
    total_beds: 2,
    monthly_rent: 17000,
    security_deposit_amount: 17000,
    has_ac: false,
    has_attached_bathroom: true,
    has_balcony: false,
    description: "1st Floor - 2 Sharing (PKR 17,000/seat)",
  })),
  {
    room_number: "Single Economy",
    floor_number: 1,
    block_name: "Main Building",
    room_type: "Single Economy",
    total_beds: 1,
    monthly_rent: 28000,
    security_deposit_amount: 28000,
    has_ac: false,
    has_attached_bathroom: true,
    has_balcony: false,
    description: "1st Floor - Single Economy - 1 Seat (PKR 28,000/month)",
  },
  {
    room_number: "Single Deluxe",
    floor_number: 1,
    block_name: "Main Building",
    room_type: "Single Deluxe",
    total_beds: 1,
    monthly_rent: 33000,
    security_deposit_amount: 33000,
    has_ac: true,
    has_attached_bathroom: true,
    has_balcony: false,
    description: "1st Floor - Single Deluxe - 1 Seat (PKR 33,000/month)",
  },
  // 2nd Floor (floor_number: 2) - Rooms 17 to 24
  ...Array.from({ length: 8 }, (_, i) => ({
    room_number: String(i + 17),
    floor_number: 2,
    block_name: "Main Building",
    room_type: "2 Sharing",
    total_beds: 2,
    monthly_rent: 17000,
    security_deposit_amount: 17000,
    has_ac: false,
    has_attached_bathroom: true,
    has_balcony: false,
    description: "2nd Floor - 2 Sharing (PKR 17,000/seat)",
  })),
  // 3rd Floor (floor_number: 3) - Room 25 & Room 26
  {
    room_number: "25",
    floor_number: 3,
    block_name: "Main Building",
    room_type: "3 Sharing",
    total_beds: 3,
    monthly_rent: 15000,
    security_deposit_amount: 15000,
    has_ac: false,
    has_attached_bathroom: true,
    has_balcony: false,
    description: "3rd Floor - 3 Sharing (PKR 15,000/seat)",
  },
  {
    room_number: "26",
    floor_number: 3,
    block_name: "Main Building",
    room_type: "2 Sharing",
    total_beds: 2,
    monthly_rent: 17000,
    security_deposit_amount: 17000,
    has_ac: false,
    has_attached_bathroom: false,
    has_balcony: false,
    description: "3rd Floor - 2 Sharing - Without Attached Washroom (PKR 17,000/seat)",
  },
];

const letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";

async function main() {
  let roomsProcessed = 0;
  let bedsCreated = 0;

  for (const spec of seedRooms) {
    const { data: existing } = await sb
      .from("rooms")
      .select("id")
      .eq("room_number", spec.room_number)
      .maybeSingle();

    let roomId;
    if (existing) {
      const { data: existingBeds } = await sb
        .from("beds")
        .select("id, status")
        .eq("room_id", existing.id);
      const occupiedCount = (existingBeds ?? []).filter(
        (b) => b.status === "Occupied",
      ).length;
      const roomStatus =
        occupiedCount >= spec.total_beds
          ? "Occupied"
          : occupiedCount > 0
            ? "Partially Occupied"
            : "Available";

      const { error: updateErr } = await sb
        .from("rooms")
        .update({
          ...spec,
          occupied_beds: occupiedCount,
          status: roomStatus,
          updated_at: new Date().toISOString(),
        })
        .eq("id", existing.id);
      if (updateErr) throw updateErr;
      roomId = existing.id;
    } else {
      const { data: inserted, error: insertErr } = await sb
        .from("rooms")
        .insert({
          ...spec,
          occupied_beds: 0,
          status: "Available",
        })
        .select("id")
        .single();
      if (insertErr) throw insertErr;
      roomId = inserted.id;
    }
    roomsProcessed++;

    const { data: currentBeds } = await sb
      .from("beds")
      .select("id, bed_number")
      .eq("room_id", roomId);

    const existingLabels = new Set(
      (currentBeds ?? []).map((b) => b.bed_number.toLowerCase()),
    );

    for (let i = 0; i < spec.total_beds; i++) {
      const desiredLabel = `${spec.room_number} ${letters[i]}`;
      if (!existingLabels.has(desiredLabel.toLowerCase())) {
        const { data: refreshedBeds } = await sb
          .from("beds")
          .select("id")
          .eq("room_id", roomId);
        if ((refreshedBeds ?? []).length < spec.total_beds) {
          const { error: bedErr } = await sb.from("beds").insert({
            room_id: roomId,
            bed_number: desiredLabel,
            status: "Vacant",
            mattress_condition: "Good",
            mattress_cover: "Available",
          });
          if (bedErr) throw bedErr;
          bedsCreated++;
        }
      }
    }
  }

  console.log(`Seed complete: ${roomsProcessed} rooms, ${bedsCreated} new beds created.`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
