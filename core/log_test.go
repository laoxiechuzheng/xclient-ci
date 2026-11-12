//go:build !cgo && !android

package core

import (
	"encoding/json"
	"reflect"
	"testing"

	"github.com/metacubex/mihomo/common/observable"
	"github.com/metacubex/mihomo/log"
)

func TestLogPumpKeepsUserLevelAndManagedFailureEvents(t *testing.T) {
	previous := log.Level()
	defer log.SetLevel(previous)
	for _, test := range []struct {
		level             log.LogLevel
		ordinary, managed []log.LogLevel
	}{
		{log.DEBUG, []log.LogLevel{log.DEBUG, log.INFO, log.WARNING, log.ERROR}, []log.LogLevel{log.DEBUG, log.INFO, log.WARNING, log.ERROR}},
		{log.INFO, []log.LogLevel{log.INFO, log.WARNING, log.ERROR}, []log.LogLevel{log.INFO, log.WARNING, log.ERROR}},
		{log.WARNING, []log.LogLevel{log.WARNING, log.ERROR}, []log.LogLevel{log.WARNING, log.ERROR}},
		{log.ERROR, []log.LogLevel{log.ERROR}, []log.LogLevel{log.WARNING, log.ERROR}},
		{log.SILENT, []log.LogLevel{}, []log.LogLevel{log.WARNING, log.ERROR}},
	} {
		t.Run(test.level.String(), func(t *testing.T) {
			log.SetLevel(test.level)
			frames := captureFrames(t, func() {
				events := make(chan log.Event, 4)
				for _, eventLevel := range []log.LogLevel{log.DEBUG, log.INFO, log.WARNING, log.ERROR} {
					events <- log.Event{LogLevel: eventLevel, Payload: "log-threshold-" + eventLevel.String()}
				}
				close(events)
				pump := logPump{subscription: observable.Subscription[log.Event](events)}
				pump.run()
				managedWait()
			})
			seen := map[string]bool{}
			for _, frame := range frames {
				var call struct {
					Arguments []struct {
						Type MessageType `json:"type"`
						Data log.Event   `json:"data"`
					} `json:"arguments"`
				}
				if err := json.Unmarshal(frame, &call); err != nil {
					t.Fatal(err)
				}
				for _, message := range call.Arguments {
					if message.Type == LogMessage {
						seen[message.Data.Payload] = true
					}
				}
			}
			expected := test.ordinary
			if IsManagedBuild() {
				expected = test.managed
			}
			got := []log.LogLevel{}
			for _, eventLevel := range []log.LogLevel{log.DEBUG, log.INFO, log.WARNING, log.ERROR} {
				if seen["log-threshold-"+eventLevel.String()] {
					got = append(got, eventLevel)
				}
			}
			if !reflect.DeepEqual(got, expected) {
				t.Fatalf("managed=%t user=%s forwarded=%v, want %v", IsManagedBuild(), test.level, got, expected)
			}
			if log.Level() != test.level {
				t.Fatal("RPC filtering changed the user's native logger threshold")
			}
		})
	}
}

func TestLogPumpStoppedStillDrainsWithoutEvents(t *testing.T) {
	frames := captureFrames(t, func() {
		events := make(chan log.Event, 1)
		events <- log.Event{LogLevel: log.ERROR, Payload: "stopped-log-pump"}
		close(events)
		pump := logPump{subscription: observable.Subscription[log.Event](events)}
		pump.stopped.Store(true)
		pump.run()
		managedWait()
	})
	if len(frames) != 0 {
		t.Fatal("stopped log pump still published events")
	}
}
