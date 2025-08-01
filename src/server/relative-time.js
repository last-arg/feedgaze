// Source: https://github.com/chrisburnell/relative-time
// Modified
 
export default class RelativeTime extends HTMLElement {
	static register(tagName) {
		if ("customElements" in window) {
			customElements.define(tagName || "relative-time", RelativeTime);
		}
	}

	static observedAttributes = [
		"lang",
		"update",
		"division",
		"max-division",
		"format-numeric",
		"numeric-format",
		"format-style",
		"style-format",
	];

	connectedCallback() {
		if (this.timeElements.length === 0) {
			return;
		}

		this.lastUpdate = 0;
		this.updateLoop;

		this.setString();

		if (this.enableUpdates && typeof requestAnimationFrame === "function") {
			this.beginUpdateLoop();
			const { signal } = (this.controller = new AbortController());
			window.addEventListener(
				"focus",
				() => {
					this.windowFocusHandler();
				},
				{ signal },
			);
			window.addEventListener(
				"blur",
				() => {
					this.windowBlurHandler();
				},
				{ signal },
			);
		}
	}

	attributeChangedCallback() {
		this.setString();
	}

	disconnectedCallback() {
		if (this.controller) {
			this.controller.abort();
		}
		if (this.observer) {
			this.observer.disconnect();
		}
	}

	getRelativeTime(datetime, division) {
		let difference = (datetime.getTime() - Date.now()) / 1000;

		if (division) {
			return this.rtf.format(Math.round(difference), division);
		}

		for (const division of RelativeTime.divisions) {
			if (
				this.maxDivision &&
				division.name === this.maxDivision.replace(/s$/, "")
			) {
				return this.rtf.format(Math.round(difference), division.name);
			}
			if (Math.floor(Math.abs(difference)) < division.amount) {
				return this.rtf.format(Math.round(difference), division.name);
			}
			difference /= division.amount;
		}
	}

	getRelativeTimeParts(datetime, division) {
		let difference = (datetime.getTime() - Date.now()) / 1000;

		if (division) {
			return this.rtf.format(Math.round(difference), division);
		}

		for (const division of RelativeTime.divisions) {
			if (
				this.maxDivision &&
				division.name === this.maxDivision.replace(/s$/, "")
			) {
				return this.rtf.formatToParts(Math.round(difference), division.name);
			}
			if (Math.floor(Math.abs(difference)) < division.amount) {
				return this.rtf.formatToParts(Math.round(difference), division.name);
			}
			difference /= division.amount;
		}
	}
	
	getDateTime(dateString) {
		const datetime = new Date(dateString);
		return !isNaN(datetime) ? datetime : null;
	}

	setString() {
		this.timeElements.forEach((element) => {
			const datetime = this.getDateTime(element.getAttribute("datetime"));
			if (!datetime) {
				return;
			}
			let output = "";
			if (datetime > Date.now() || !element.closest(".feed-item")) {
				output = this.getRelativeTime(datetime, this.division);
			} else {
				let parts = this.getRelativeTimeParts(datetime, this.division);
				output += parts[0].value;
				if (parts[0].unit === "month") {
					output += "M"
				} else if (parts[0].unit === "year") {
					output += "Y"
				} else {
					output += parts[0].unit[0]
				}
			}

			element.innerHTML = output;
			const title = datetime.toLocaleString(undefined, {
				timeZoneName: "short",
			});
			if (element.title !== title) {
				element.title = title;
			}
		});
	}

	beginUpdateLoop() {
		const updateLoop = (currentTime) => {
			this.updateLoop = requestAnimationFrame(updateLoop);
			if (currentTime - this.lastUpdate >= this.update * 1000) {
				this.setString();
				this.lastUpdate = currentTime;
			}
		};
		this.updateLoop = requestAnimationFrame(updateLoop);
	}

	stopUpdateLoop() {
		this.lastUpdate = 0;
		cancelAnimationFrame(this.updateLoop);
	}

	windowFocusHandler() {
		this.setString();
		this.beginUpdateLoop();
	}

	windowBlurHandler() {
		this.stopUpdateLoop();
	}

	static divisions = [
		{
			amount: 60,
			name: "second",
		},
		{
			amount: 60,
			name: "minute",
		},
		{
			amount: 24,
			name: "hour",
		},
		{
			amount: 7,
			name: "day",
		},
		{
			amount: 4.34524,
			name: "week",
		},
		{
			amount: 12,
			name: "month",
		},
		{
			amount: Number.POSITIVE_INFINITY,
			name: "year",
		},
	];

	static numericFormats = ["always", "auto"];

	static styleFormats = ["long", "short", "narrow"];

	get locale() {
		return (
			this.getAttribute("lang") ||
			this.closest("[lang]")?.getAttribute("lang") ||
			undefined
		);
	}

	get rtf() {
		return new Intl.RelativeTimeFormat(this.locale, {
			localeMatcher: "best fit",
			numeric: this.formatNumeric,
			style: this.formatStyle,
		});
	}

	get timeElements() {
		return this.querySelectorAll("time[datetime]");
	}

	get division() {
		return this.getAttribute("division");
	}

	get maxDivision() {
		return this.getAttribute("max-division");
	}

	get formatNumeric() {
		// default = "auto"
		const numericFormat =
			this.getAttribute("format-numeric") ||
			this.getAttribute("numeric-format");
		if (
			numericFormat &&
			RelativeTime.numericFormats.includes(numericFormat)
		) {
			return numericFormat;
		} else if (this.division || this.maxDivision) {
			return "always";
		}
		return "auto";
	}

	get formatStyle() {
		// default = "long"
		const styleFormat =
			this.getAttribute("format-style") ||
			this.getAttribute("style-format");
		if (styleFormat && RelativeTime.styleFormats.includes(styleFormat)) {
			return styleFormat;
		}
		return "long";
	}

	get update() {
		// default = 600 seconds = 10 minutes
		return this.hasAttribute("update")
			? Number(this.getAttribute("update"))
			: 600;
	}

	get enableUpdates() {
		return this.getAttribute("update") !== "false";
	}
}

RelativeTime.register();

