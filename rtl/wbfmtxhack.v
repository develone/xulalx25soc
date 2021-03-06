////////////////////////////////////////////////////////////////////////////////
//
// Filename: 	wbfmtxhack.v
//		
// Project:	A Wishbone Controlled FM Transmitter Hack
//
// Purpose:	This Hack is based off of two things: 1) the interface spec
//		of the WB controlled PWM audio device, and 2) a Raspberry Pi
//	Hack I was shown that converted the RPi PWM device into an FM
//	transmitter.  So, the question is, can a GPIO pin be turned into an
//	FM transmitter that can be heard throughout the house?
//
//	We'll try and do this properly: We'll use a Numerically Controlled
//	Oscillator to generate our signal, but only grab the top bit out of
//	that oscillator.  We'll then send this bit to the GPIO pin (a.k.a.
//	antenna) to see if it can accomplish our goals.
//
//	WB Control/Registers:
//	1'b0:	Next Sample
//
//		The top bits of this 'next sample' will indicate the number
//		of clock ticks before we generate a need next sample interrupt.
//		If these top bits are zero, the sample rate will not be
//		adjusted.  The value to set here is the value of the clock
//		rate divided by the desired sample rate.  Hence, if the clock
//		rate is 80MHz, setting this to 10e3 (unsigned) would set us up
//		for an 8kHz sample rate, whereas setting these upper 16 bits to
//		1814 would specify a sample rate closer to 44.1kHz.
//
//		The lower 16 bits specify the value of the next sample.
//
//		Since we'll be dealing with FM modulation, we'll try to arrange
//		that this sixteen bit sample will correspond to a maximum
//		FM deviation of about 75 kHz.
//
//
//	1'b1:	The Oscillator "Frequency" (really stepsize).  This should be
//		used to control/determine the "RF frequency" this device can
//		transmit on.  
//
//		To transmit at 0Hz, set this to zero.  To transmit at
//		CLKSPEED/2 Hz, set this to 32'h8000_0000.  Hence for a 
//		transmit frequency of X, set this value to 
//
//		OSXFREQ = 2^32 * X / CLKSPEED
//
//		Where X and CLKSPEED share the same units.  But how shall we
//		transmit at speeds of anything higher than CLKSPEED/2?  By
//		aliasing up.  Hence, set X to your actual frequency value,
//		divide by the clockspeed and multiply by 2^32.  Remove any
//		bits that don't fit in the top 32 and you are there.
//
//		This also gives us about 20 mHz resolution for our Carrier
//		frequency--overkill perhaps, but it should work.
//
//	So ... how do we create our 75 kHz deviation?  We want:
//
//	MAX_STEPSIZE = 2^32 * (X + 75kHz * sample / 2^15) / CLKSPEED
//	= OSXFREQ = (2^32 * sample / 2^15 / CLKSPEED * 75 kHz)
//	= 123 * sample ~= 128 * sample = sample << 7.
//
//	Thus, by shifting our input sample value a touch, we can multiply by
//	nearly the exact constant we want.
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2015-2016, Gisselquist Technology, LLC
//
// This program is free software (firmware): you can redistribute it and/or
// modify it under the terms of  the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
// for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program.  (It's in the $(ROOT)/doc directory.  Run make with no
// target there if the PDF file isn't present.)  If not, see
// <http://www.gnu.org/licenses/> for a copy.
//
// License:	GPL, v3, as defined and found on www.gnu.org,
//		http://www.gnu.org/licenses/gpl.html
//
//
////////////////////////////////////////////////////////////////////////////////
//
//
module	wbfmtxhack(i_clk, 
		// Wishbone interface
		i_wb_cyc, i_wb_stb, i_wb_we, i_wb_addr, i_wb_data,
			o_wb_ack, o_wb_stall, o_wb_data,
		o_tx, o_int);
	parameter	DEFAULT_RELOAD = 16'd1814; // 44.1kHz at a 80MHz clock
	input	i_clk;
	input	i_wb_cyc, i_wb_stb, i_wb_we;
	input		i_wb_addr;
	input	[31:0]	i_wb_data;
	output	reg		o_wb_ack;
	output	wire		o_wb_stall;
	output	reg	[31:0]	o_wb_data;
	output	wire		o_tx;
	output	reg		o_int;

	reg	[31:0]	nco_step, nco_phase;

	// How often shall we create an interrupt?  Every reload_value clocks!
	// If VARIABLE_RATE==0, this value will never change and will be kept
	// at the default reload rate (44.1 kHz, for a 100 MHz clock)
	reg	[15:0]	reload_value;
	initial	reload_value = DEFAULT_RELOAD;

	// Data write, but we use the upper 16 bits to set our sample rate.
	// If these bits are zero, we ignore the write--allowing users to
	// write samples without adjusting the sample rate.
	always @(posedge i_clk) // Set sample rate
		if ((i_wb_stb)&&(~i_wb_addr)&&(i_wb_we)
				&&(|i_wb_data[31:16]))
			reload_value <= i_wb_data[31:16];

	// Set the NCO transmit frequency
	initial	nco_step = 32'h00;
	always @(posedge i_clk)
		if ((i_wb_stb)&&(i_wb_addr)&&(i_wb_we))
			nco_step <= i_wb_data[31:0];

	reg		ztimer;
	reg	[15:0]	timer;
	initial	ztimer = 1'b0;
	always @(posedge i_clk) // Be true when the timer is zero
		ztimer <= (timer[15:0] == 16'h1);
	initial	timer = reload_value;
	always @(posedge i_clk)
		if (ztimer)
			timer <= reload_value;
		else
			timer <= timer - 16'h1;

	reg	[15:0]	next_sample, sample_out;
	initial	sample_out  = 16'h00;
	initial	next_sample = 16'h00;
	always @(posedge i_clk)
		if (ztimer)
			sample_out <= next_sample;

	reg		next_valid;
	initial	next_valid = 1'b1;
	initial	next_sample = 16'h8000;
	always @(posedge i_clk) // Data write
		if ((i_wb_stb)&&(i_wb_we)&&(~i_wb_addr))
		begin
			// Write with two's complement data
			next_sample <= i_wb_data[15:0];
			next_valid <= 1'b1;
		end else if (ztimer)
			next_valid <= 1'b0;

	// The interrupt line will remain high until writing a new data value
	// clears it.  This design does not permit turning off this interrupt.
	// If the interrupt needs to be turned off, then ignore it in the 
	// interrupt controller.
	initial	o_int = 1'b0;
	always @(posedge i_clk)
		o_int <= (~next_valid);

	// Adjust the gain for a maximum frequency offset just greater than
	// 75 kHz.  (We would've done 75kHz exactly, but it required a multiply
	// and this doesn't.)
	initial	nco_phase = 32'h00;
	always @(posedge i_clk)
		nco_phase <= nco_phase + nco_step
			+ { {(32-16-7){sample_out[15]}}, sample_out, 7'h00 };
	assign	o_tx = nco_phase[31];

	always @(posedge i_clk)
		if (i_wb_addr)
			o_wb_data <= nco_step;
		else
			o_wb_data <= { reload_value, sample_out[15:1], o_int };

	initial	o_wb_ack = 1'b0;
	always @(posedge i_clk)
		o_wb_ack <= (i_wb_stb);
	assign	o_wb_stall = 1'b0;

endmodule
