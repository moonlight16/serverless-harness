package vmpool

import (
	"io/fs"
	"path/filepath"
)

// jailStats is an inventory of what one Destroy's os.RemoveAll is about to unlink,
// split by whether the unlink actually frees anything.
//
// The distinction is the entire point (#307 Q4). Restore hardlinks five golden-snapshot
// components and the run's workspace.img into the jail, so those inodes have nlink > 1
// and dropping the jail's reference releases no blocks at all -- the snapshot directory
// and the run's WorkspaceDir still hold them. Only entries the jail itself owns
// (nlink == 1) -- in practice the jailer's ~3.6 MiB copy of the exec-file, plus the
// API/vsock sockets and the mknod'd device nodes, which are 0 bytes -- are storage this
// unlink returns.
//
// So `linked` counts dentry work and `owned_bytes` counts block work, and only the
// second is a number a thin-provisioning or storage-layer argument can spend.
type jailStats struct {
	entries, dirs           int64
	linked, owned           int64
	linkedBytes, ownedBytes int64
	blocks512               int64
}

// jailInventory walks a jail root and classifies its entries. Errors are swallowed
// deliberately: this runs inside Destroy purely to describe a teardown that is about to
// happen anyway, and a VM must not fail to be destroyed because a diagnostic could not
// stat something. A partial inventory reads as smaller counts, which is why the caller
// logs it next to the removeall timing rather than on its own.
func jailInventory(root string) jailStats {
	var s jailStats
	_ = filepath.WalkDir(root, func(_ string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		s.entries++
		if d.IsDir() {
			s.dirs++
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		nlink, blocks := statLinksAndBlocks(info)
		s.blocks512 += blocks
		if nlink > 1 {
			s.linked++
			s.linkedBytes += info.Size()
			return nil
		}
		s.owned++
		s.ownedBytes += info.Size()
		return nil
	})
	return s
}
