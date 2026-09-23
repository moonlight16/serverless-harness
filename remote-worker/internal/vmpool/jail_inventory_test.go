//go:build unix

package vmpool

import (
	"os"
	"path/filepath"
	"testing"
)

// The freed/not-freed split is the only thing jailStats is for, so it is pinned directly
// rather than inferred from a Destroy. A jail's five snapshot components and workspace.img
// are hardlinks whose inodes outlive the jail, and reading their size as "freed" is what
// would restart the thin-provisioning conversation #307 closed with 3.51 MiB.
func TestJailInventorySeparatesHardlinksFromOwnedData(t *testing.T) {
	root := t.TempDir()
	jail := filepath.Join(root, "jail")
	if err := os.MkdirAll(filepath.Join(jail, "run"), 0o755); err != nil {
		t.Fatal(err)
	}
	// The "golden snapshot": an inode outside the jail, hardlinked in. Unlinking the jail's
	// name frees nothing while this one survives.
	golden := filepath.Join(root, "memfile")
	if err := os.WriteFile(golden, make([]byte, 8192), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(golden, filepath.Join(jail, "memfile")); err != nil {
		t.Fatal(err)
	}
	// The jailer's exec-file copy: owned by the jail, and the only thing whose blocks the
	// unlink returns.
	if err := os.WriteFile(filepath.Join(jail, "firecracker"), make([]byte, 4096), 0o644); err != nil {
		t.Fatal(err)
	}

	inv := jailInventory(jail)
	if inv.linked != 1 || inv.linkedBytes != 8192 {
		t.Errorf("linked=%d linkedBytes=%d, want 1 and 8192 (the hardlink, whose bytes are NOT freed)",
			inv.linked, inv.linkedBytes)
	}
	if inv.owned != 1 || inv.ownedBytes != 4096 {
		t.Errorf("owned=%d ownedBytes=%d, want 1 and 4096 (the jail's own copy)",
			inv.owned, inv.ownedBytes)
	}
	if inv.dirs != 2 {
		t.Errorf("dirs=%d, want 2 (the jail root and run/)", inv.dirs)
	}
	if inv.entries != 4 {
		t.Errorf("entries=%d, want 4 (two dirs plus two files)", inv.entries)
	}
	// Split rather than summed: a combined block total is dominated by the shared snapshot
	// components, which buries the owned-bytes-against-owned-blocks comparison that is the
	// only reason to report allocated size at all.
	if inv.ownedBlocks512 <= 0 {
		t.Errorf("ownedBlocks512=%d, want > 0 for a 4096-byte file", inv.ownedBlocks512)
	}
	if inv.linkedBlocks512 <= 0 {
		t.Errorf("linkedBlocks512=%d, want > 0 for an 8192-byte file", inv.linkedBlocks512)
	}
}

// A jail that has already been removed must not panic or invent counts: Destroy calls this
// for diagnostics only, and a VM must never fail to be destroyed because a stat did not land.
func TestJailInventoryOnAMissingRootIsEmpty(t *testing.T) {
	inv := jailInventory(filepath.Join(t.TempDir(), "gone"))
	if inv.entries != 0 || inv.linked != 0 || inv.owned != 0 {
		t.Errorf("inventory of a missing root = %+v, want all zero", inv)
	}
}
