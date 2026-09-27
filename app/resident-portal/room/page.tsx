export default function ResidentRoomPage() {
  return (
    <main className="mx-auto max-w-6xl p-4 sm:p-6">
      <h1 className="mb-4 text-2xl font-bold sm:mb-6 sm:text-4xl">Resident Room</h1>
      <div className="grid grid-cols-1 gap-4 rounded-xl border p-4 sm:grid-cols-2 sm:gap-6 sm:p-6">
        <div><strong>Room:</strong> 101</div>
        <div><strong>Bed:</strong> B1</div>
        <div><strong>Floor:</strong> 2nd</div>
        <div><strong>Building:</strong> A Block</div>
        <div><strong>Room Type:</strong> Shared</div>
        <div><strong>Status:</strong> Occupied</div>
      </div>
    </main>
  );
}