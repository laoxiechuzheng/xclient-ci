package core

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"testing"
)

func TestDirectControlHarness(t *testing.T) {
	if os.Getenv("XC_DIRECT_TEST_BRIDGE") != "1" {
		t.Skip("opt-in stdio bridge for the Dart/Go TLS integration fixture")
	}
	output := os.Stdout
	os.Stdout = os.Stderr
	initDirectControl()
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 4096), 16*1024)
	for scanner.Scan() {
		var call MethodCall
		var response []byte
		if json.Unmarshal(scanner.Bytes(), &call) != nil {
			response = encodeResponse(MethodResponse{Error: &MethodError{Code: "invalid_arguments", Message: "invalid direct control frame"}})
		} else if call.Method != openDirectSocketMethod && call.Method != closeDirectSocketMethod && call.Method != closeDirectSessionMethod {
			response = encodeResponse(MethodResponse{ID: call.ID, Error: &MethodError{Code: "not_implemented", Message: "not a direct control method"}})
		} else {
			response = handleMethodCall(&call)
		}
		if _, err := fmt.Fprintln(output, string(response)); err != nil {
			shutdownDirectControl()
			os.Exit(2)
		}
	}
	shutdownDirectControl()
	if scanner.Err() != nil {
		os.Exit(2)
	}
	os.Exit(0)
}
