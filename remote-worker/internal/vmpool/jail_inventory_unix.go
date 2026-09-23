//go:build unix

package vmpool

import (
	"io/fs"
	"syscall"
)

// statLinksAndBlocks reports an entry's link count and its allocated 512-byte blocks.
//
// Nlink is widened rather than compared at its native width because its type differs by
// platform (uint64 on linux/amd64, uint16 on darwin), and this file is built for both.
// Blocks is the ALLOCATED size, which is why it is reported alongside the apparent size:
// on a sparse or thin-provisioned image the two disagree, and that gap is exactly what a
// storage-layer proposal would be claiming to exploit.
func statLinksAndBlocks(info fs.FileInfo) (uint64, int64) {
	st, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return 1, 0
	}
	return uint64(st.Nlink), int64(st.Blocks)
}
