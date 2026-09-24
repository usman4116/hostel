import Link from "next/link";
export default function AddResidentPage() {
  return <main className="p-8"><h1 className="text-2xl font-bold">Register a resident</h1>
    <p className="my-4">Use Add Resident on the residents page to complete the profile. Assign a room and bed through Admissions after registration.</p>
    <Link className="text-indigo-700 underline" href="/residents">Open residents</Link></main>;
}
