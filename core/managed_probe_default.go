//go:build !xclient

package core

import (
	"context"

	"github.com/metacubex/mihomo/constant"
)

func delayProbeContext(ctx context.Context, _, _ string) context.Context { return ctx }

func allowDelayProbe(constant.Proxy) bool { return true }

func IsManagedBuild() bool { return false }
