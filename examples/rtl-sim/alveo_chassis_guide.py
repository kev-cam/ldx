#!/usr/bin/env python3
"""
alveo_chassis_guide.py — Practical guide for building Alveo U250 acceleration clusters

Analysis of chassis options, power/cooling requirements, and cost-effective deployment
strategies for RTL simulation acceleration.
"""

from dataclasses import dataclass
from typing import List, Dict
import json

@dataclass
class ChassisOption:
    """Chassis specification for Alveo deployment."""
    name: str
    form_factor: str
    max_alveo_cards: int
    pcie_slots: str
    power_supply_w: int
    cooling: str
    typical_cost_used: int
    pros: List[str]
    cons: List[str]
    best_for: str

class AlveoChassisAnalyzer:
    """Analyze chassis options for Alveo U250 deployment."""

    def __init__(self):
        self.alveo_specs = {
            "power_consumption_w": 75,
            "pcie_requirement": "PCIe 4.0 x16 (works in x8)",
            "length_mm": 267,
            "height_mm": 111,  # Dual-slot
            "cooling_required": "Active cooling, good airflow"
        }

    def get_chassis_options(self) -> List[ChassisOption]:
        """Define chassis options for Alveo deployment."""

        return [
            ChassisOption(
                name="Dell PowerEdge R750",
                form_factor="2U Server",
                max_alveo_cards=3,
                pcie_slots="3x PCIe 4.0 x16",
                power_supply_w=1100,
                cooling="Enterprise server cooling",
                typical_cost_used=1500,
                pros=[
                    "Enterprise reliability",
                    "Excellent cooling",
                    "Remote management (iDRAC)",
                    "Dual PSU redundancy"
                ],
                cons=[
                    "Limited to 3 cards",
                    "More expensive than alternatives",
                    "Overkill for simple deployments"
                ],
                best_for="Production environments, 3-card clusters"
            ),

            ChassisOption(
                name="Supermicro SYS-420GP-TNAR",
                form_factor="4U Server",
                max_alveo_cards=8,
                pcie_slots="8x PCIe 4.0 x16",
                power_supply_w=2000,
                cooling="High-airflow server cooling",
                typical_cost_used=2500,
                pros=[
                    "8 full-size PCIe slots",
                    "Designed for GPU/accelerator workloads",
                    "Excellent power delivery",
                    "Great expandability"
                ],
                cons=[
                    "Higher upfront cost",
                    "4U height requirement",
                    "Power hungry even when idle"
                ],
                best_for="8-card acceleration clusters, serious deployments"
            ),

            ChassisOption(
                name="HP Z8 G4 Workstation",
                form_factor="Workstation Tower",
                max_alveo_cards=4,
                pcie_slots="7x PCIe 3.0/4.0 slots",
                power_supply_w=1450,
                cooling="Workstation cooling",
                typical_cost_used=800,
                pros=[
                    "Very cost effective used",
                    "Great for development",
                    "Dual Xeon capability",
                    "Quiet operation"
                ],
                cons=[
                    "Tower form factor",
                    "Limited rack mounting",
                    "Some slots may be x8"
                ],
                best_for="Development workstations, small clusters"
            ),

            ChassisOption(
                name="Custom Build (Threadripper)",
                form_factor="ATX/EATX",
                max_alveo_cards=4,
                pcie_slots="4x PCIe 4.0 x16",
                power_supply_w=1600,
                cooling="Custom cooling solution",
                typical_cost_used=1200,
                pros=[
                    "Customizable",
                    "High single-thread performance",
                    "Latest PCIe 4.0/5.0 support",
                    "Cost effective"
                ],
                cons=[
                    "No enterprise features",
                    "Single PSU",
                    "DIY assembly required"
                ],
                best_for="High-performance single nodes, cost optimization"
            ),

            ChassisOption(
                name="Used Cisco UCS C240 M5",
                form_factor="2U Server",
                max_alveo_cards=2,
                pcie_slots="2x PCIe 3.0 x16",
                power_supply_w=1050,
                cooling="Enterprise cooling",
                typical_cost_used=600,
                pros=[
                    "Very affordable used",
                    "Enterprise build quality",
                    "Good for 2-card setups",
                    "Rack mountable"
                ],
                cons=[
                    "Limited to 2 cards",
                    "PCIe 3.0 (not 4.0)",
                    "Older platform"
                ],
                best_for="Budget 2-card clusters, testing/development"
            ),

            ChassisOption(
                name="GIGABYTE G482-Z54",
                form_factor="4U Server",
                max_alveo_cards=10,
                pcie_slots="10x PCIe 4.0 x16",
                power_supply_w=3000,
                cooling="Extreme airflow design",
                typical_cost_used=4000,
                pros=[
                    "Maximum density (10 cards)",
                    "Purpose-built for accelerators",
                    "Dual AMD EPYC support",
                    "Enterprise features"
                ],
                cons=[
                    "Very expensive",
                    "High power consumption",
                    "Complex cooling requirements",
                    "Overkill for most uses"
                ],
                best_for="Maximum density deployments, data centers"
            )
        ]

    def analyze_deployment_scenarios(self) -> Dict:
        """Analyze different deployment scenarios."""

        scenarios = {
            "development_workstation": {
                "description": "Single developer, RTL acceleration testing",
                "recommended_cards": 1,
                "chassis_recommendation": "HP Z8 G4 Workstation",
                "total_cost_estimate": 4800,  # $4K card + $800 chassis
                "use_cases": ["RTL development", "Synthesis testing", "Algorithm validation"]
            },

            "small_team": {
                "description": "Small team, multiple concurrent simulations",
                "recommended_cards": 2,
                "chassis_recommendation": "Used Cisco UCS C240 M5",
                "total_cost_estimate": 8600,  # $8K cards + $600 chassis
                "use_cases": ["Parallel development", "Regression testing", "Small ASIC verification"]
            },

            "asic_team": {
                "description": "Full ASIC team, complex SoC verification",
                "recommended_cards": 4,
                "chassis_recommendation": "Dell PowerEdge R750 or Custom Build",
                "total_cost_estimate": 17500,  # $16K cards + $1.5K chassis
                "use_cases": ["Full SoC simulation", "Verification clusters", "Performance analysis"]
            },

            "production_cluster": {
                "description": "Multiple teams, continuous verification",
                "recommended_cards": 8,
                "chassis_recommendation": "Supermicro SYS-420GP-TNAR",
                "total_cost_estimate": 34500,  # $32K cards + $2.5K chassis
                "use_cases": ["CI/CD acceleration", "Multiple concurrent projects", "Performance regression"]
            },

            "enterprise_deployment": {
                "description": "Large organization, multiple clusters",
                "recommended_cards": 32,
                "chassis_recommendation": "4x Supermicro SYS-420GP-TNAR",
                "total_cost_estimate": 138000,  # $128K cards + $10K chassis
                "use_cases": ["Enterprise RTL simulation", "Multiple product lines", "Research & development"]
            }
        }

        return scenarios

    def calculate_power_and_cooling(self, num_cards: int) -> Dict:
        """Calculate power and cooling requirements."""

        card_power = num_cards * self.alveo_specs["power_consumption_w"]
        system_overhead = 200  # Base system power
        total_power = card_power + system_overhead

        # Cooling requirements (typical server efficiency)
        cooling_btu_per_hour = total_power * 3.41  # Watts to BTU/h conversion

        return {
            "cards": num_cards,
            "card_power_w": card_power,
            "total_system_power_w": total_power,
            "recommended_psu_w": int(total_power * 1.2),  # 20% headroom
            "cooling_btu_per_hour": int(cooling_btu_per_hour),
            "cooling_notes": f"Need {int(cooling_btu_per_hour/1000)}K BTU/h cooling capacity"
        }

    def create_buying_guide(self) -> Dict:
        """Create practical buying guide."""

        return {
            "ebay_tips": [
                "Look for 'tested working' or 'pulled from working system'",
                "Verify firmware version (should be recent)",
                "Check seller feedback for enterprise hardware",
                "Factor in shipping costs (~$50-100 for servers)"
            ],

            "inspection_checklist": [
                "Physical damage to card or connectors",
                "Fan operation (if applicable)",
                "FPGA temperature sensors functional",
                "PCIe lane detection at full speed",
                "Xilinx platform cable detection"
            ],

            "additional_costs": {
                "cables": "JTAG cables, power adapters: $50-200",
                "cooling": "Additional case fans: $50-100",
                "networking": "10G/25G switches for clusters: $500-2000",
                "software": "Vivado licenses (if not using free version): $0-5000"
            },

            "timeline": {
                "sourcing": "2-4 weeks (eBay, surplus dealers)",
                "assembly": "1-2 days per chassis",
                "testing": "1 week initial validation",
                "integration": "2-4 weeks software setup"
            }
        }

    def print_analysis(self):
        """Print complete analysis."""

        print("Alveo U250 Cluster Building Guide")
        print("=" * 50)
        print(f"Alveo U250 eBay price: $4,000")
        print(f"Power per card: {self.alveo_specs['power_consumption_w']}W")
        print(f"PCIe requirement: {self.alveo_specs['pcie_requirement']}")
        print()

        chassis_options = self.get_chassis_options()

        print("📦 CHASSIS OPTIONS")
        print("=" * 30)

        for chassis in chassis_options:
            print(f"\n{chassis.name}")
            print(f"  Form factor: {chassis.form_factor}")
            print(f"  Max Alveo cards: {chassis.max_alveo_cards}")
            print(f"  Cost (used): ${chassis.typical_cost_used:,}")
            print(f"  Total cost with cards: ${chassis.typical_cost_used + (4000 * chassis.max_alveo_cards):,}")
            print(f"  Best for: {chassis.best_for}")
            print(f"  Pros: {', '.join(chassis.pros[:2])}")

        print(f"\n🎯 DEPLOYMENT SCENARIOS")
        print("=" * 30)

        scenarios = self.analyze_deployment_scenarios()
        for name, scenario in scenarios.items():
            print(f"\n{scenario['description']}")
            print(f"  Cards: {scenario['recommended_cards']}")
            print(f"  Chassis: {scenario['chassis_recommendation']}")
            print(f"  Total cost: ${scenario['total_cost_estimate']:,}")

        print(f"\n⚡ POWER CALCULATIONS")
        print("=" * 30)

        for cards in [1, 2, 4, 8]:
            power_info = self.calculate_power_and_cooling(cards)
            print(f"{cards} cards: {power_info['total_system_power_w']}W total, "
                  f"need {power_info['recommended_psu_w']}W PSU")

        buying_guide = self.create_buying_guide()

        print(f"\n🛒 BUYING TIPS")
        print("=" * 20)
        for tip in buying_guide["ebay_tips"]:
            print(f"  • {tip}")

def main():
    """Run chassis analysis."""

    analyzer = AlveoChassisAnalyzer()
    analyzer.print_analysis()

    print(f"\n💰 COST COMPARISON")
    print("=" * 30)
    print("Scenario: 4-card cluster for ASIC team")
    print("  New equipment: $60K (4x $15K Alveos)")
    print("  eBay equipment: $17.5K (4x $4K Alveos + chassis)")
    print("  Savings: $42.5K (71% cost reduction!)")
    print()
    print("🎯 SWEET SPOT RECOMMENDATION:")
    print("  2-4 Alveo U250s in HP Z8 G4 or Dell R750")
    print("  Total cost: $8.6K - $17.5K")
    print("  Handles 10M-50M gate ASICs efficiently")
    print("  Perfect for most ASIC verification teams")

if __name__ == "__main__":
    main()