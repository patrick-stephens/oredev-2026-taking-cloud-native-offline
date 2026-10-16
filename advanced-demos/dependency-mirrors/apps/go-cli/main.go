package main

import (
	"fmt"
	"os"

	"github.com/fatih/color"
)

func main() {
	name := "offline"
	if len(os.Args) > 1 {
		name = os.Args[1]
	}
	color.Green("hello, %s", name)
	fmt.Println("Go modules came from vendor/")
}
