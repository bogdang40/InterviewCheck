import WorkspaceBackup from "@/components/WorkspaceBackup"

export default function DataPage() {
  return (
    <>
      <div className="page-title">
        <h1>Workspace data</h1>
        <p>Back up interviews or restore them on another workstation.</p>
      </div>
      <WorkspaceBackup />
    </>
  )
}
